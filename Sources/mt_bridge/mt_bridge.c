/**
 * mt_bridge.c — MultitouchSupport.framework C 实现
 *
 * 动态加载 Apple 私有 MultitouchSupport.framework 并封装其最小 API：
 *   - 设备枚举 (MTDeviceCreateList)
 *   - 设备 ID 读取 (struct offset 64)
 *   - 触摸帧回调 (MTRegisterContactFrameCallback / MTDeviceStart/Stop)
 *   - 触觉反馈 (MTActuatorCreateFromDeviceID / Open / Actuate / Close)
 *
 * 注意事项：
 *   1. 通过 dlopen/dlsym 动态加载符号，绕开 arm64e PAC 指针对签名的依赖。
 *   2. MTDeviceGetDeviceID() 的调用约定在 Apple Silicon 上会触发 SIGBUS，
 *      因此改用从 MTDevice struct offset 64 直接读 deviceID。
 *   3. 每次调用 mt_actuate 都要重建 actuator —— mactic 实测句柄是单次使用。
 *   4. MTDeviceStart 会向 stdout/stderr 打印调试信息，因此调用前后要
 *      临时重定向到 /dev/null。
 */

#include "mt_bridge.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

#include <CoreFoundation/CoreFoundation.h>

/* ---------------------------------------------------------------------------
 * 8 个函数指针类型定义（按 MultitouchSupport 的调用约定）
 * ------------------------------------------------------------------------- */
typedef CFMutableArrayRef (*fn_MTDeviceCreateList)(void);
typedef void *       (*fn_MTActuatorCreateFromDeviceID)(uint64_t deviceID);
typedef int          (*fn_MTActuatorOpen)(void *actuator, int mode);
typedef int          (*fn_MTActuatorActuate)(void *actuator, int w1, int w2, int w3, int w4);
typedef int          (*fn_MTActuatorClose)(void *actuator);
/* mactic 逆向：这三个函数返回 void，无法靠返回值判断成功失败，
   只能靠回调是否被触发来间接感知。 */
typedef void         (*fn_MTRegisterContactFrameCallback)(void *device, void *callback, void *user_data);
typedef void         (*fn_MTDeviceStart)(void *device, int mode);
typedef void         (*fn_MTDeviceStop)(void *device);

/* ---------------------------------------------------------------------------
 * 全局状态
 * ------------------------------------------------------------------------- */
static void *g_framework    = NULL;   /* dlopen handle */
static int   g_initialized  = 0;

static fn_MTDeviceCreateList            pMTDeviceCreateList            = NULL;
static fn_MTActuatorCreateFromDeviceID  pMTActuatorCreateFromDeviceID  = NULL;
static fn_MTActuatorOpen                pMTActuatorOpen                = NULL;
static fn_MTActuatorActuate             pMTActuatorActuate             = NULL;
static fn_MTActuatorClose               pMTActuatorClose               = NULL;
static fn_MTRegisterContactFrameCallback pMTRegisterContactFrameCallback = NULL;
static fn_MTDeviceStart                 pMTDeviceStart                 = NULL;
static fn_MTDeviceStop                  pMTDeviceStop                  = NULL;

/* MTDevice struct 中 deviceID 字段的字节偏移。
 * 在 M3 MacBook Pro / Sequoia 上实测为 64；不同硬件/系统可能不同。 */
#define MTDEVICE_ID_OFFSET 64

/* ---------------------------------------------------------------------------
 * 内部：触摸回调适配器
 *  MultitouchSupport 内部回调签名 = (device, touches, nFingers, timestamp, frame, user_data)
 *  其中 touches 是 96 字节的 MTTouch 数组（与 mt_touch_t 布局一致），
 *  所以我们直接 re-cast 指针转发给 Swift 侧的 mt_touch_cb_t。
 * ------------------------------------------------------------------------- */
static mt_touch_cb_t g_user_cb    = NULL;
static void        *g_user_data  = NULL;

static void mt_internal_touch_cb(void *device,
                                 const mt_touch_t *touches,
                                 int n_fingers,
                                 double timestamp,
                                 int32_t frame,
                                 void *user_data /* 保留，实际我们用全局 g_user_data */)
{
    (void)user_data;
    /* n_fingers 来自逆向的私有回调签名，必须在最靠近源头处钳制：
       负值/超大值/空指针会在 Swift 侧变成越界读与无界分配。
       触控板物理上限远小于 MT_MAX_FINGERS（32）。 */
    if (!touches || n_fingers <= 0 || n_fingers > MT_MAX_FINGERS) {
        return;
    }
    /* 同一份 (cb, user_data) 快照：避免读取期间被 mt_stop_touch 改成 cb 非空但 data 为 NULL */
    mt_touch_cb_t cb = g_user_cb;
    void *data = g_user_data;
    if (cb) {
        cb((mt_device_t)device, touches, n_fingers, timestamp, frame, data);
    }
}

/* ---------------------------------------------------------------------------
 * 内部：MTDeviceStart 打印静音
 * ------------------------------------------------------------------------- */
static void redirect_stdfd_to_null(int *save_out, int *save_err)
{
    *save_out = dup(STDOUT_FILENO);
    *save_err = dup(STDERR_FILENO);
    int nul = open("/dev/null", O_WRONLY);
    if (nul >= 0) {
        dup2(nul, STDOUT_FILENO);
        dup2(nul, STDERR_FILENO);
        close(nul);
    }
}
static void restore_stdfd(int save_out, int save_err)
{
    if (save_out >= 0) { dup2(save_out, STDOUT_FILENO); close(save_out); }
    if (save_err >= 0) { dup2(save_err, STDERR_FILENO); close(save_err); }
}

/* 自定义波形通路（可编程触觉）。
 * 这两个符号属于「宿主自定义波形」能力：MTActuationCreateFromDictionary 把参数字典
 * 编译成波形对象，MTActuationActuate 再经由 waveformID=83（宿主自定义槽）下发。
 * 以软解析方式获取——缺失时 mt_actuate_custom 返回 -1，不影响预设波形通路。 */
typedef CFTypeRef (*fn_MTActuationCreateFromDictionary)(CFDictionaryRef, void *);
typedef int       (*fn_MTActuationActuate)(CFTypeRef, void *, void *);

static fn_MTActuationCreateFromDictionary pMTActuationCreateFromDictionary = NULL;
static fn_MTActuationActuate             pMTActuationActuate             = NULL;

/* ---------------------------------------------------------------------------
 * 生命周期：mt_init / mt_shutdown
 * ------------------------------------------------------------------------- */
int mt_init(void)
{
    if (g_initialized) return 0;

    g_framework = dlopen("/System/Library/PrivateFrameworks/"
                         "MultitouchSupport.framework/MultitouchSupport",
                         RTLD_LAZY);
    if (!g_framework) {
        fprintf(stderr, "[mt_bridge] dlopen failed: %s\n", dlerror());
        return -1;
    }

    /* 逐个解析 8 个符号，任何一个缺失都视为不可用。 */
#define RESOLVE(sym, field) do { \
    field = (__typeof__(field))dlsym(g_framework, #sym); \
    if (!field) { \
        fprintf(stderr, "[mt_bridge] dlsym(" #sym ") failed: %s\n", dlerror()); \
        goto fail; \
    } \
} while (0)

    RESOLVE(MTDeviceCreateList,            pMTDeviceCreateList);
    RESOLVE(MTActuatorCreateFromDeviceID,  pMTActuatorCreateFromDeviceID);
    RESOLVE(MTActuatorOpen,                pMTActuatorOpen);
    RESOLVE(MTActuatorActuate,             pMTActuatorActuate);
    RESOLVE(MTActuatorClose,               pMTActuatorClose);
    RESOLVE(MTRegisterContactFrameCallback, pMTRegisterContactFrameCallback);
    RESOLVE(MTDeviceStart,                 pMTDeviceStart);
    RESOLVE(MTDeviceStop,                  pMTDeviceStop);
#undef RESOLVE

    /* 软解析：自定义波形为可选增强能力，缺失不阻断基础触觉 */
    pMTActuationCreateFromDictionary =
        (fn_MTActuationCreateFromDictionary)dlsym(g_framework, "MTActuationCreateFromDictionary");
    pMTActuationActuate =
        (fn_MTActuationActuate)dlsym(g_framework, "MTActuationActuate");

    g_initialized = 1;
    return 0;

fail:
    dlclose(g_framework);
    g_framework = NULL;
    return -1;
}

void mt_shutdown(void)
{
    pMTDeviceCreateList            = NULL;
    pMTActuatorCreateFromDeviceID  = NULL;
    pMTActuatorOpen                = NULL;
    pMTActuatorActuate             = NULL;
    pMTActuatorClose               = NULL;
    pMTRegisterContactFrameCallback = NULL;
    pMTDeviceStart                 = NULL;
    pMTDeviceStop                  = NULL;
    pMTActuationCreateFromDictionary = NULL;
    pMTActuationActuate              = NULL;
    if (g_framework) {
        dlclose(g_framework);
        g_framework = NULL;
    }
    g_initialized = 0;
}

#include <IOKit/IOKitLib.h>

/* ---------------------------------------------------------------------------
 * 设备发现
 * ------------------------------------------------------------------------- */
mt_device_t *mt_scan_devices(int *out_count)  /* 兼容旧 API，deprecated */
{
    *out_count = 0;
    if (!g_initialized) return NULL;

    CFMutableArrayRef list = pMTDeviceCreateList();
    if (!list) return NULL;

    CFIndex n = CFArrayGetCount(list);
    if (n <= 0) {
        CFRelease(list);
        return NULL;
    }

    size_t bytes = (size_t)n * sizeof(mt_device_t);
    mt_device_t *result = (mt_device_t *)malloc(bytes);
    if (!result) {
        CFRelease(list);
        return NULL;
    }

    for (CFIndex i = 0; i < n; ++i) {
        const void *p = CFArrayGetValueAtIndex(list, i);
        CFRetain((CFTypeRef)p);   /* caller 需要存活，手动 retain */
        result[i] = (mt_device_t)p;
    }
    *out_count = (int)n;
    CFRelease(list);
    return result;
}

int mt_scan_devices_array(void * _Nonnull * _Nonnull out_array)
{
    if (!g_initialized || !out_array) return 0;
    *out_array = NULL;
    CFMutableArrayRef list = pMTDeviceCreateList();
    if (!list) return 0;
    CFIndex n = CFArrayGetCount(list);
    *out_array = (void *)list;  /* 不 release，交给 caller 通过 mt_release_devices_array 释放 */
    return (int)n;
}

void mt_release_devices_array(void * _Nullable array)
{
    if (!array) return;
    CFRelease((CFTypeRef)array);
}

mt_device_t _Nullable mt_device_at_index(void * _Nonnull array, int idx)
{
    if (!array || idx < 0) return NULL;
    CFArrayRef arr = (CFArrayRef)array;
    if (idx >= (int)CFArrayGetCount(arr)) return NULL;
    const void *p = CFArrayGetValueAtIndex(arr, (CFIndex)idx);
    return (mt_device_t)p;
}

/* ---------------------------------------------------------------------------
 * deviceID 读取
 *   方案 A（offset 64）：struct offset 读取。如果对象不是实际 MTDevice 内存（例如只
 *     暴露了 isa 指针），读到的全是 0。
 *   方案 B（IORegistry）：更可靠。通过 IOIterator 找 AppleMultitouchDevice，
 *     按 index 匹配到 MTDeviceCreateList 返回的数组。
 * ------------------------------------------------------------------------- */
uint64_t mt_device_get_id(mt_device_t dev)
{
    if (!dev) return 0;
    uint64_t devID = 0;
    memcpy(&devID, (const uint8_t *)dev + MTDEVICE_ID_OFFSET, sizeof(devID));
    return devID;
}

uint64_t mt_device_get_id_by_index(int index)
{
    if (index < 0) return 0;

    /* 方案 B：IORegistry 枚举 AppleMultitouchDevice 的 "mt-device-id" */
    CFMutableDictionaryRef match = IOServiceMatching("AppleMultitouchDevice");
    if (!match) return 0;
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return 0;

    uint64_t found = 0;
    int i = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iter)) != 0) {
        if (i == index) {
            CFTypeRef prop = IORegistryEntryCreateCFProperty(
                service,
                CFSTR("mt-device-id"),
                kCFAllocatorDefault,
                0
            );
            if (prop) {
                if (CFGetTypeID(prop) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt64Type, &found);
                }
                CFRelease(prop);
            }
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
        ++i;
    }
    IOObjectRelease(iter);
    if (found != 0) return found;

    /* 没找到 "mt-device-id"，尝试同级 IOHIDInterface 下找带 mt-device-id 的父节点 */
    match = IOServiceMatching("AppleMultitouchTrackpadHIDEventDriver");
    if (!match) return 0;
    iter = 0;
    kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (kr != KERN_SUCCESS) return 0;
    i = 0;
    while ((service = IOIteratorNext(iter)) != 0) {
        if (i == index) {
            /* 沿 registry tree 向上查父节点属性 */
            io_registry_entry_t parent = 0;
            kern_return_t kr2 = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent);
            if (kr2 == KERN_SUCCESS) {
                CFTypeRef prop = IORegistryEntryCreateCFProperty(
                    parent,
                    CFSTR("mt-device-id"),
                    kCFAllocatorDefault, 0
                );
                if (prop) {
                    if (CFGetTypeID(prop) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt64Type, &found);
                    }
                    CFRelease(prop);
                }
                IOObjectRelease(parent);
            }
            IOObjectRelease(service);
            break;
        }
        IOObjectRelease(service);
        ++i;
    }
    IOObjectRelease(iter);
    return found;
}

/* ---------------------------------------------------------------------------
 * 触摸数据流
 * ------------------------------------------------------------------------- */
int mt_start_touch(mt_device_t dev, mt_touch_cb_t cb, void *user_data)
{
    if (!g_initialized || !dev || !cb) return -1;

    g_user_cb   = cb;
    g_user_data = user_data;

    /* mactic 逆向：MTRegisterContactFrameCallback / MTDeviceStart 返回 void，
       无法靠返回值判断成功失败，只能靠回调是否被触发来间接感知。 */
    pMTRegisterContactFrameCallback(dev, (void *)mt_internal_touch_cb, NULL);

    int so = -1, se = -1;
    redirect_stdfd_to_null(&so, &se);   /* 屏蔽 "Recognized (0x6f) family..." 噪音 */
    pMTDeviceStart(dev, 0);
    restore_stdfd(so, se);
    return 0;
}

void mt_stop_touch(mt_device_t dev)
{
    /* 先摘掉回调再停设备：MTDeviceStop 返回后仍可能有已在飞行中的帧到达回调，
       若先停设备后清 cb，那段窗口里回调仍会带着旧 user_data 进入 Swift 侧。
       先置 NULL 可让任何迟到帧在 mt_internal_touch_cb 的 cb 检查处直接丢弃。
       （注意：pMTDeviceStop 本身是同步调用，这里不引入额外阻塞。） */
    g_user_cb   = NULL;
    g_user_data = NULL;
    if (g_initialized && dev) {
        pMTDeviceStop(dev);
    }
}

/* ---------------------------------------------------------------------------
 * 触觉反馈
 * ------------------------------------------------------------------------- */
int mt_actuate(uint64_t deviceID, int waveformID)
{
    if (!g_initialized) return -1;
    if (waveformID < 1 || waveformID > 64) return -1;

    void *actuator = pMTActuatorCreateFromDeviceID(deviceID);
    if (!actuator) {
        return -1;
    }

    int rc = pMTActuatorOpen(actuator, 0);
    if (rc != 0) {
        CFRelease(actuator);
        return -1;
    }
    /* 后三个参数的作用未知，mactic 固定传 0/0/0 */
    (void)pMTActuatorActuate(actuator, waveformID, 0, 0, 0);
    (void)pMTActuatorClose(actuator);
    CFRelease(actuator);
    return 0;
}

/* ---------------------------------------------------------------------------
 * 自定义波形（可编程触觉）
 *
 * 与 mt_actuate 的区别：mt_actuate 只能播 Apple 出厂预设（waveformID 1~64），
 * 本函数按调用方给出的物理参数现场编译一个波形并播放——走的是框架内部的
 * 「宿主自定义波形」槽位（实测为 waveformID 83），与预设波形互不干扰。
 *
 * 参数结构严格对齐 Apple 产线 actuation 定义（BaseWaveform + Tones +
 * Base/ToneMultipliers），证据见 docs/research/自定义波形可行性.md。
 * ------------------------------------------------------------------------- */
static CFNumberRef mt_num_int(int v)
{
    return CFNumberCreate(NULL, kCFNumberIntType, &v);
}

static CFNumberRef mt_num_double(double v)
{
    return CFNumberCreate(NULL, kCFNumberDoubleType, &v);
}

int mt_actuate_custom(uint64_t deviceID, mt_waveform_t wf)
{
    /* -1 = 能力不可用（框架未初始化 / 私有符号缺失）→ 调用方应回退预设波形 */
    if (!g_initialized) return -1;
    if (!pMTActuationCreateFromDictionary || !pMTActuationActuate) return -1;

    int rc = -2;   /* -2 = 参数被拒 / 设备不可用（不触发回退，避免双震） */
    CFTypeRef actuation = NULL;
    void *actuator = NULL;
    int opened = 0;

    /* ---- BaseWaveform ---- */
    CFStringRef envType = CFStringCreateWithCString(NULL, wf.envelope_type,
                                                    kCFStringEncodingUTF8);
    if (!envType) return -1;
    CFNumberRef envDur = mt_num_int((int)wf.envelope_duration_ms);
    CFNumberRef envAmp = mt_num_double(wf.envelope_amplitude);
    const void *baseKeys[] = { CFSTR("Type"), CFSTR("DurationMS"), CFSTR("Amplitude") };
    const void *baseVals[] = { envType, envDur, envAmp };
    CFDictionaryRef base = CFDictionaryCreate(NULL, baseKeys, baseVals, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    /* ---- Tones[0] ---- */
    CFStringRef toneType = CFStringCreateWithCString(NULL, wf.tone_type,
                                                     kCFStringEncodingUTF8);
    CFNumberRef toneFreq = mt_num_double(wf.tone_frequency_khz);
    CFNumberRef toneAmp  = mt_num_double(wf.tone_amplitude);
    CFNumberRef toneDur  = mt_num_int((int)wf.tone_duration_ms);
    CFNumberRef toneDelay = mt_num_int((int)wf.tone_delay_ms);
    CFDictionaryRef tone = NULL;
    CFArrayRef tones = NULL;
    if (toneType) {
        const void *toneKeys[] = { CFSTR("Type"), CFSTR("FrequencykHz"),
                                   CFSTR("Amplitude"), CFSTR("DurationMS"),
                                   CFSTR("DelayMS") };
        const void *toneVals[] = { toneType, toneFreq, toneAmp, toneDur, toneDelay };
        tone = CFDictionaryCreate(NULL, toneKeys, toneVals, 5,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (tone) {
            const void *oneTone[] = { tone };
            tones = CFArrayCreate(NULL, oneTone, 1, &kCFTypeArrayCallBacks);
        }
    }

    /* ---- 按压力度乘法器 ---- */
    CFNumberRef eL = mt_num_double(wf.envelope_light);
    CFNumberRef eM = mt_num_double(wf.envelope_medium);
    CFNumberRef eF = mt_num_double(wf.envelope_firm);
    const void *mulKeys[] = { CFSTR("Light"), CFSTR("Medium"), CFSTR("Firm") };
    const void *envMulVals[] = { eL, eM, eF };
    CFDictionaryRef envMul = CFDictionaryCreate(NULL, mulKeys, envMulVals, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CFNumberRef tL = mt_num_double(wf.tone_light);
    CFNumberRef tM = mt_num_double(wf.tone_medium);
    CFNumberRef tF = mt_num_double(wf.tone_firm);
    const void *toneMulVals[] = { tL, tM, tF };
    CFDictionaryRef toneMul = CFDictionaryCreate(NULL, mulKeys, toneMulVals, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    /* ---- 顶层字典 ---- */
    if (base && tones && envMul && toneMul) {
        const void *topKeys[] = { CFSTR("BaseWaveform"), CFSTR("Tones"),
                                  CFSTR("BaseMultipliers"), CFSTR("ToneMultipliers") };
        const void *topVals[] = { base, tones, envMul, toneMul };
        CFDictionaryRef dict = CFDictionaryCreate(NULL, topKeys, topVals, 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (dict) {
            /* 编译波形（无 BaseWaveform 键时框架返回 NULL） */
            actuation = pMTActuationCreateFromDictionary(dict, NULL);
            CFRelease(dict);
        }
    }

    /* ---- 播放 ---- */
    if (actuation) {
        actuator = pMTActuatorCreateFromDeviceID(deviceID);
        if (actuator && pMTActuatorOpen(actuator, 0) == 0) {
            opened = 1;
            rc = pMTActuationActuate(actuation, actuator, NULL);
        }
    }

    /* ---- 清理（严格对称，避免每次震动泄漏） ---- */
    if (opened) {
        (void)pMTActuatorClose(actuator);
    }
    if (actuator) CFRelease(actuator);
    if (actuation) CFRelease(actuation);
    if (base) CFRelease(base);
    if (tone) CFRelease(tone);
    if (tones) CFRelease(tones);
    if (envMul) CFRelease(envMul);
    if (toneMul) CFRelease(toneMul);
    if (envType) CFRelease(envType);
    if (toneType) CFRelease(toneType);
    if (envDur) CFRelease(envDur);
    if (envAmp) CFRelease(envAmp);
    if (toneFreq) CFRelease(toneFreq);
    if (toneAmp) CFRelease(toneAmp);
    if (toneDur) CFRelease(toneDur);
    if (toneDelay) CFRelease(toneDelay);
    if (eL) CFRelease(eL);
    if (eM) CFRelease(eM);
    if (eF) CFRelease(eF);
    if (tL) CFRelease(tL);
    if (tM) CFRelease(tM);
    if (tF) CFRelease(tF);
    return rc;
}

/* ---------------------------------------------------------------------------
 * 诊断：MTDevice struct 原始字节 dump（按 uint64_t / uint32_t 双视图打印）
 * 目标：手动定位 deviceID 字段。我们会在 Swift 侧直接调用 dump。
 * ------------------------------------------------------------------------- */
void mt_device_dump_struct(mt_device_t dev, int start, int nbytes)
{
    if (!dev || start < 0 || nbytes <= 0) return;
    const uint8_t *base = (const uint8_t *)dev;

    /* 每 16 字节一行：偏移 + 4 个 uint32 + 2 个 uint64 + ASCII */
    for (int off = start & ~0xF; off < start + nbytes; off += 16) {
        uint32_t w[4] = {0};
        uint64_t q[2] = {0};
        char ascii[17];
        for (int i = 0; i < 16; ++i) {
            uint8_t b = base[off + i];
            if (i % 4 == 0) {
                w[i / 4] = (uint32_t)b;
            } else {
                w[i / 4] |= ((uint32_t)b) << (8 * (i % 4));
            }
            if (i % 8 == 0) {
                q[i / 8] = (uint64_t)b;
            } else {
                q[i / 8] |= ((uint64_t)b) << (8 * (i % 8));
            }
            ascii[i] = (b >= 0x20 && b < 0x7f) ? (char)b : '.';
        }
        ascii[16] = 0;
        fprintf(stderr,
                "[mt_dev] +%04x | "
                "%08x %08x %08x %08x  "
                "%016llx %016llx  |%s|\n",
                off,
                w[0], w[1], w[2], w[3],
                (unsigned long long)q[0], (unsigned long long)q[1],
                ascii);
    }
}

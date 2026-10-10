/*
 * probe4.c — 自定义波形「物理通路」验证
 *
 * 会真实触发触控板震动（这是本探针的目的）。
 * 顺序：原生 ID 2（参照）→ 自定义波形。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

#define FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

typedef void *(*fnCreatFromDevID)(uint64_t);
typedef int   (*fnOpen)(void *, int);
typedef int   (*fnActuatorActuate)(void *, int, int, int, int);
typedef int   (*fnClose)(void *);
typedef CFTypeRef (*fnActuationFromDict)(CFDictionaryRef, void *);
typedef int   (*fnActuationActuate)(CFTypeRef, void *, void *);

static CFNumberRef numI(int v) { return CFNumberCreate(NULL, kCFNumberIntType, &v); }
static CFNumberRef numD(double v) { return CFNumberCreate(NULL, kCFNumberDoubleType, &v); }

/* 自定义波形：低频长音（与原生 1~6 的短促 click 明显不同） */
static CFDictionaryRef customWave(void) {
    CFMutableDictionaryRef base = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(base, CFSTR("Type"),       CFSTR("Gaussian"));
    CFDictionarySetValue(base, CFSTR("DurationMS"), numI(8));
    CFDictionarySetValue(base, CFSTR("Amplitude"),  numD(20));

    CFMutableDictionaryRef tone = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(tone, CFSTR("Type"),         CFSTR("Sine"));
    CFDictionarySetValue(tone, CFSTR("FrequencykHz"), numD(0.05));
    CFDictionarySetValue(tone, CFSTR("Amplitude"),    numD(0.30));
    CFDictionarySetValue(tone, CFSTR("DurationMS"),   numI(60));
    CFDictionarySetValue(tone, CFSTR("DelayMS"),      numI(0));
    CFArrayRef tones = CFArrayCreate(NULL, (const void **)&tone, 1, &kCFTypeArrayCallBacks);

    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("BaseWaveform"), base);
    CFDictionarySetValue(d, CFSTR("Tones"),        tones);
    return d;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    void *H = dlopen(FW, RTLD_LAZY);
    if (!H) { printf("dlopen failed\n"); return 1; }

    CFMutableArrayRef (*createList)(void) = dlsym(H, "MTDeviceCreateList");
    fnCreatFromDevID actCreate = dlsym(H, "MTActuatorCreateFromDeviceID");
    fnOpen          actOpen    = dlsym(H, "MTActuatorOpen");
    fnActuatorActuate actAct   = dlsym(H, "MTActuatorActuate");
    fnClose         actClose   = dlsym(H, "MTActuatorClose");
    fnActuationFromDict  actFromDict = dlsym(H, "MTActuationCreateFromDictionary");
    fnActuationActuate   actnAct     = dlsym(H, "MTActuationActuate");

    CFMutableArrayRef list = createList();
    void *dev = (void *)CFArrayGetValueAtIndex(list, 0);
    uint64_t devID = *(uint64_t *)((const char *)dev + 64);
    printf("[dev] deviceID = 0x%llx\n", (unsigned long long)devID);

    /* ---- 参照：原生 ID 2（强 click，App 当前用法） ---- */
    {
        void *a = actCreate(devID);
        if (a && actOpen(a, 0) == 0) {
            printf("[ref] 播放原生波形 ID 2 ...\n");
            int rc = actAct(a, 2, 0, 0, 0);
            printf("[ref] MTActuatorActuate(ID=2) rc=%d\n", rc);
            actClose(a);
        } else { printf("[ref] actuator 打开失败\n"); }
    }
    sleep(2);

    /* ---- 自定义波形 ---- */
    if (!actFromDict || !actnAct) { printf("[custom] 符号缺失\n"); return 2; }
    CFDictionaryRef w = customWave();
    CFTypeRef actuation = actFromDict(w, NULL);
    printf("[custom] MTActuationCreateFromDictionary -> %p\n", actuation);
    if (!actuation) { printf("[custom] 字典被拒绝\n"); return 3; }

    void *a = actCreate(devID);
    if (!a) { printf("[custom] actuator 创建失败\n"); return 4; }
    printf("[custom] open = %d\n", actOpen(a, 0));

    printf("[custom] 播放自定义波形（低频 0.05kHz / 60ms 长音）...\n");
    int rc = actnAct(actuation, a, NULL);
    printf("[custom] MTActuationActuate rc=%d (0 = 成功)\n", rc);
    sleep(1);
    rc = actnAct(actuation, a, NULL);
    printf("[custom] 第二次 rc=%d\n", rc);

    actClose(a);
    return 0;
}

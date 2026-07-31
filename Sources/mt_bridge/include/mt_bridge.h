/**
 * mt_bridge.h — MultitouchSupport.framework Swift 桥接头
 *
 * 向 Swift 暴露一个极小的 C API，封装 Apple 私有 MultitouchSupport.framework 的
 * 设备发现、触摸回调、触觉反馈能力。所有私有框架符号在 mt_bridge.c 内部通过
 * dlopen/dlsym 解析，避免 Swift 直接链接私有库（也绕开 arm64e PAC 认证问题）。
 *
 * 蓝本：GitHub MatMercer/mactic (implementation.md)
 */

#ifndef MT_BRIDGE_H
#define MT_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * MTTouch struct（96 字节，与 Apple 私有 MTTouch 内存布局一致）
 * 字段来源：mactic 通过 dump 原始字节 + 物理动作交叉引用确定
 * ------------------------------------------------------------------------- */
typedef struct {
    int32_t  frame;          /* +0  帧计数（与回调最后一个参数相等） */
    int32_t  _pad4;          /* +4  恒为 0 */
    double   timestamp;      /* +8  Mach absolute time, seconds */
    int32_t  pathIndex;      /* +16 手指追踪 ID，跨帧稳定 */
    int32_t  state;          /* +20 触摸阶段：1 start / 3 make / 4 touch / 5 press / 6 tap / 7 lift */
    int32_t  fingerID;       /* +24 手指分类器 */
    int32_t  handID;         /* +28 手分类器 */
    float    norm_x;         /* +32 归一化 X：0.0 (左)  ~ 1.0 (右) */
    float    norm_y;         /* +36 归一化 Y：0.0 (上)  ~ 1.0 (下) */
    float    vel_x;          /* +40 归一化速度 X */
    float    vel_y;          /* +44 归一化速度 Y */
    float    size;           /* +48 瞬时压力/接触面积：~0.3 轻 → ~1.35 重 （最佳动态范围）*/
    float    pressure;       /* +52 累积压力（不建议用，持续累加） */
    float    angle;          /* +56 接触椭圆角度 rad */
    float    majorAxis;      /* +60 接触椭圆长轴 mm */
    float    minorAxis;      /* +64 接触椭圆短轴 mm */
    float    density;        /* +68 密度（会出现负数） */
    float    abs_x;          /* +72 绝对 X mm （左边缘=0） */
    float    abs_vel_x;      /* +76 绝对速度 X mm/s */
    float    abs_vel_y;      /* +80 绝对速度 Y mm/s */
    int32_t  _pad84;         /* +84 保留 */
    int32_t  _pad88;         /* +88 保留 */
    float    zPressure;      /* +92 Z 轴压力，上限 ~1.54 */
} mt_touch_t;

/* 静态断言：一旦 struct 大小偏离 96，立刻报编译错误，避免 silent 越界读 */
_Static_assert(sizeof(mt_touch_t) == 96, "mt_touch_t must be exactly 96 bytes");

/* 触摸阶段常量（对应 state 字段） */
enum {
    MT_STATE_NONE  = 0,
    MT_STATE_START = 1,
    MT_STATE_HOVER = 2,   /* 悬停，未接触 */
    MT_STATE_MAKE  = 3,   /* 首次接触瞬间 */
    MT_STATE_TOUCH = 4,   /* 持续接触 */
    MT_STATE_PRESS = 5,   /* Force Touch 阈值越过 */
    MT_STATE_TAP   = 6,   /* 短暂点击 */
    MT_STATE_LIFT  = 7    /* 手指离开 */
};

/* ---------------------------------------------------------------------------
 * Opaque 设备句柄 = 私有框架的 MTDevice* 指针。
 * Swift 侧只持有句柄，不直接访问内部字段。
 * ------------------------------------------------------------------------- */
typedef void* mt_device_t;

/* ---------------------------------------------------------------------------
 * 触摸回调签名（@convention(c)，可直接传入 Swift 闭包）
 *   dev       : 当前帧所属的 mt_device_t
 *   touches   : 长度 = n_fingers 的 mt_touch_t 数组（只读，有效期=回调内）
 *   n_fingers : 当前激活手指数量（0 = 无手指，但通常 0 时不回调）
 *   timestamp : Mach absolute time in seconds
 *   frame     : 单调帧计数
 *   user_data : mt_start_touch() 传入的指针原样回传
 * ------------------------------------------------------------------------- */
typedef void (*mt_touch_cb_t)(
    mt_device_t       dev,
    const mt_touch_t *touches,
    int               n_fingers,
    double            timestamp,
    int32_t           frame,
    void             *user_data
);

/* ---------------------------------------------------------------------------
 * 生命周期
 * ------------------------------------------------------------------------- */

/**
 * 初始化：dlopen MultitouchSupport.framework，dlsym 解析所有需要的符号。
 * @return 0 成功 / -1 失败（框架不可用或符号缺失）
 */
int mt_init(void);

/**
 * 清理：dlclose 框架句柄（通常程序退出前调）。
 */
void mt_shutdown(void);

/* ---------------------------------------------------------------------------
 * 设备枚举
 * ------------------------------------------------------------------------- */

/**
 * 扫描所有 multitouch 设备。
 * @param out_array 输出参数：返回 void*（实际是 CFMutableArrayRef）。
 *                  调用者必须调用 mt_release_devices_array(*out_array) 释放。
 *                  若失败或未找到，*out_array = NULL，返回 0。
 * @return          设备数量
 *
 * 为什么不用 malloc 返回设备数组？
 *   因为 CFArray 元素（MTDevice CF 对象）是被数组 retain 的，
 *   如果我们只拷贝 void* 然后立刻 CFRelease 数组，元素会被释放，
 *   后续的 MTRegisterContactFrameCallback / MTDeviceStart 就会访问悬空指针并失败。
 */
int mt_scan_devices_array(void * _Nullable * _Nonnull out_array);

/**
 * 释放 mt_scan_devices_array 返回的 CFArray（内部会 CFRelease）。
 * 传 NULL 安全。
 */
void mt_release_devices_array(void * _Nullable array);

/**
 * 从 mt_scan_devices_array 返回的数组中取第 idx 个元素的原始设备指针。
 * 不做 retain（数组持有）。
 */
mt_device_t _Nullable mt_device_at_index(void * _Nonnull array, int idx);

/**
 * @deprecated 使用 mt_scan_devices_array 替代
 */
mt_device_t * _Nullable mt_scan_devices(int * _Nonnull out_count) __attribute__((deprecated("use mt_scan_devices_array instead")));

/**
 * 从 MTDevice 结构体的已知偏移读取 64-bit deviceID。
 * offset=64 在 M3 / Sequoia 验证通过；如其它机型读错，请重新探测见 implementation.md。
 * 若 struct 未被填充（返回 0），请改用 mt_device_get_id_hint()。
 */
uint64_t mt_device_get_id(mt_device_t dev);

/**
 * 通过设备在 CFArray 中的索引匹配 deviceID：
 *   扫描 IORegistry (AppleMultitouchDevice) 的 "mt-device-id" 属性，
 *   按顺序匹配到 MTDeviceCreateList 的 CFArray 元素。
 * 比 offset=64 读取更可靠，兼容不同硬件/系统版本。
 *
 * @param  index  mt_scan_devices_array 返回数组中的下标
 * @return        64-bit deviceID，找不到返回 0
 */
uint64_t mt_device_get_id_by_index(int index);

/* ---------------------------------------------------------------------------
 * 触摸数据流
 * ------------------------------------------------------------------------- */

/**
 * 在指定设备上启动触摸回调。同一设备只能有一个活跃回调（再次调用会覆盖）。
 * @return 0 成功 / -1 失败（框架未初始化 / 回调注册失败）
 */
int  mt_start_touch(mt_device_t dev, mt_touch_cb_t cb, void *user_data);

/**
 * 停止触摸回调。之后不会再触发 cb。
 */
void mt_stop_touch(mt_device_t dev);

/* ---------------------------------------------------------------------------
 * 触觉反馈（Actuator）
 *
 * waveform 已知有效值（以 mactic -l 探测到的为准）：
 *   1 弱 click  / 2 强 click (Force Touch) / 3 buzz
 *   4 轻 tap   / 5 中 tap   / 6 强 tap
 *   15 软重击  / 16 强重击
 * ------------------------------------------------------------------------- */

/**
 * 触发一次触觉反馈波形（Fire & Forget）。
 * 每次调用都会创建新 actuator 句柄（mactic 观察到句柄是单次使用的）。
 * @return 0 成功 / -1 失败
 */
int mt_actuate(uint64_t deviceID, int waveformID);

/**
 * 诊断：将 MTDevice 结构体指定字节范围按 uint64_t 打印（每行 8 字节 + 偏移）。
 * 用于在不同硬件/系统上重新探测 deviceID 字段的正确偏移。
 * （mactic 原版 offset=64 仅在 M3/Sequoia 验证通过；其它机型可能不同）
 *
 * @param dev     要 dump 的设备
 * @param start   起始偏移（建议 0）
 * @param nbytes  总字节数（建议 192 或 256）
 */
void mt_device_dump_struct(mt_device_t dev, int start, int nbytes);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MT_BRIDGE_H */

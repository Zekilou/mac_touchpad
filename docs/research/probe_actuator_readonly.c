/*
 * probe.c — 自定义波形可行性探测（只读，不改变任何系统状态）
 *
 * 目的：确认 MultitouchSupport.framework 是否暴露「可编程波形」通路。
 * 只调用查询类接口（Get/Supports/Is），不做任何 Actuate。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

#define FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

typedef void *MTDeviceRef;
typedef void *MTActuatorRef;

static void *H;

static void *sym(const char *n) {
    void *p = dlsym(H, n);
    printf("[sym] %-46s %s\n", n, p ? "ok" : "MISSING");
    return p;
}

static void dumpCF(const char *label, CFTypeRef v) {
    printf("---- %s ----\n", label);
    printf("ptr = %p\n", v);
    if (!v) { printf("(null)\n"); return; }
    CFTypeID tid = CFGetTypeID(v);
    printf("typeID = %lu  (dict=%lu array=%lu string=%lu data=%lu num=%lu)\n",
           (unsigned long)tid,
           (unsigned long)CFDictionaryGetTypeID(),
           (unsigned long)CFArrayGetTypeID(),
           (unsigned long)CFStringGetTypeID(),
           (unsigned long)CFDataGetTypeID(),
           (unsigned long)CFNumberGetTypeID());
    CFShow(v);
    printf("\n---- end %s ----\n", label);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    H = dlopen(FW, RTLD_LAZY);
    if (!H) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    printf("[ok] dlopen\n");

    CFMutableArrayRef (*createList)(void)              = sym("MTDeviceCreateList");
    MTDeviceRef       (*createDefault)(void)           = sym("MTDeviceCreateDefault");
    MTActuatorRef     (*devGetActuator)(MTDeviceRef)   = sym("MTDeviceGetMTActuator");
    int               (*devSupportsActuation)(MTDeviceRef) = sym("MTDeviceSupportsActuation");
    MTActuatorRef     (*actCreateFromDevID)(uint64_t)  = sym("MTActuatorCreateFromDeviceID");
    int               (*actOpen)(MTActuatorRef, int)   = sym("MTActuatorOpen");
    int               (*actIsOpen)(MTActuatorRef)      = sym("MTActuatorIsOpen");
    int               (*actGetSysEnabled)(MTActuatorRef) = sym("MTActuatorGetSystemActuationsEnabled");
    CFTypeRef         (*actGetProdPlist)(MTActuatorRef) = sym("MTActuatorGetProductionPlist");

    MTDeviceRef dev = NULL;

    /* --- 路径 A：设备列表 --- */
    if (createList) {
        CFMutableArrayRef list = createList();
        printf("[dev] MTDeviceCreateList -> %p\n", list);
        if (list) {
            CFIndex n = CFArrayGetCount(list);
            printf("[dev] count = %ld\n", (long)n);
            if (n > 0) {
                dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, 0);
                CFRetain(dev);
                printf("[dev] dev[0] = %p\n", dev);
            }
        }
    }

    /* --- 路径 B：默认设备 --- */
    if (!dev && createDefault) {
        dev = createDefault();
        printf("[dev] MTDeviceCreateDefault -> %p\n", dev);
    }
    if (!dev) { printf("[dev] 无可用设备（可能缺少输入监控权限）\n"); return 2; }

    if (devSupportsActuation)
        printf("[dev] MTDeviceSupportsActuation = %d\n", devSupportsActuation(dev));

    /* --- 路径 1：直接从设备拿 actuator --- */
    if (devGetActuator) {
        MTActuatorRef a = devGetActuator(dev);
        printf("[act] MTDeviceGetMTActuator -> %p\n", a);
        if (a) {
            if (actIsOpen)       printf("[act] isOpen = %d\n", actIsOpen(a));
            if (actGetSysEnabled) printf("[act] systemActuationsEnabled = %d\n", actGetSysEnabled(a));
            if (actGetProdPlist) dumpCF("ProductionPlist (via MTDeviceGetMTActuator)", actGetProdPlist(a));
        }
    }

    /* --- 路径 2：deviceID（offset 64，避开 MTDeviceGetDeviceID 的 SIGBUS） --- */
    uint64_t devID = *(uint64_t *)((const char *)dev + 64);
    printf("[dev] deviceID@offset64 = 0x%llx (%llu)\n",
           (unsigned long long)devID, (unsigned long long)devID);

    if (devID && actCreateFromDevID) {
        MTActuatorRef a2 = actCreateFromDevID(devID);
        printf("[act] CreateFromDeviceID -> %p\n", a2);
        if (a2) {
            if (actIsOpen) printf("[act] isOpen = %d\n", actIsOpen(a2));
            if (actOpen)   printf("[act] open(0) = %d\n", actOpen(a2, 0));
            if (actGetProdPlist) dumpCF("ProductionPlist (via CreateFromDeviceID)", actGetProdPlist(a2));
        }
    }
    return 0;
}

/*
 * probe3.c — 验证 MTActuationCreateFromDictionary 是否接受任意波形字典
 *
 * 只创建对象并 CFShow，不调用任何 Actuate —— 不会产生震动、不改变系统状态。
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

#define FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

typedef CFTypeRef (*fnCreateFromDict)(CFDictionaryRef, void *);

static CFTypeRef mkDict(void) {
    /* 完全自定义：长 duration + 更低频 tone，明显区别于原生 1~6 */
    CFMutableDictionaryRef base = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int dur = 40;
    double amp = 12.0;
    CFStringRef type = CFSTR("Gaussian");
    CFDictionarySetValue(base, CFSTR("DurationMS"), CFNumberCreate(NULL, kCFNumberIntType, &dur));
    CFDictionarySetValue(base, CFSTR("Amplitude"),  CFNumberCreate(NULL, kCFNumberDoubleType, &amp));
    CFDictionarySetValue(base, CFSTR("Type"),       type);

    CFMutableDictionaryRef tone = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    double f = 0.25, ta = 0.3;
    int td = 30, tdelay = 0;
    CFDictionarySetValue(tone, CFSTR("FrequencykHz"), CFNumberCreate(NULL, kCFNumberDoubleType, &f));
    CFDictionarySetValue(tone, CFSTR("Amplitude"),    CFNumberCreate(NULL, kCFNumberDoubleType, &ta));
    CFDictionarySetValue(tone, CFSTR("DurationMS"),   CFNumberCreate(NULL, kCFNumberIntType, &td));
    CFDictionarySetValue(tone, CFSTR("DelayMS"),      CFNumberCreate(NULL, kCFNumberIntType, &tdelay));
    CFDictionarySetValue(tone, CFSTR("Type"),         CFSTR("Sine"));
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
    if (!H) { printf("dlopen failed: %s\n", dlerror()); return 1; }

    fnCreateFromDict createFromDict = dlsym(H, "MTActuationCreateFromDictionary");
    printf("[sym] MTActuationCreateFromDictionary = %p\n", (void *)createFromDict);
    if (!createFromDict) return 2;

    /* ---- 1) 原生字典（从 production plist 取 ActuationID 1） ---- */
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/mt_production.plist"),
                                                 kCFURLPOSIXPathStyle, false);
    CFDataRef raw = NULL;
    FILE *f = fopen("/tmp/mt_production.plist", "rb");
    if (f) {
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        UInt8 *buf = malloc(n); fread(buf, 1, n, f); fclose(f);
        raw = CFDataCreate(NULL, buf, n); free(buf);
    }
    (void)url;
    if (raw) {
        CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, raw, 0, NULL, NULL);
        if (pl) {
            CFArrayRef def = (CFArrayRef)CFDictionaryGetValue((CFDictionaryRef)pl, CFSTR("Default"));
            if (def) {
                for (CFIndex i = 0; i < CFArrayGetCount(def); ++i) {
                    CFDictionaryRef e = CFArrayGetValueAtIndex(def, i);
                    CFNumberRef id = CFDictionaryGetValue(e, CFSTR("ActuationID"));
                    int v = -1; CFNumberGetValue(id, kCFNumberIntType, &v);
                    if (v == 1) {
                        CFDictionaryRef d1 = CFDictionaryGetValue(e, CFSTR("Default"));
                        printf("\n### 用原生 ActuationID 1 的字典调用 ###\n");
                        CFTypeRef r = createFromDict(d1, NULL);
                        printf("[result] arg1=NULL -> %p\n", r);
                        if (r) { printf("OK: 原生字典被接受\n"); CFShow(r); }
                    }
                }
            }
        }
    }

    /* ---- 2) 自定义字典 ---- */
    CFDictionaryRef custom = mkDict();
    printf("\n### 自定义波形字典 ###\n");
    CFShow(custom);
    for (int i = 0; i < 3; ++i) {
        void *arg1 = (i == 0) ? NULL : (i == 1 ? (void *)1 : (void *)2);
        CFTypeRef r = createFromDict(custom, arg1);
        printf("[result] arg1=%p -> %p %s\n", arg1, r, r ? "(接受)" : "(拒绝)");
        if (r && i == 0) CFShow(r);
    }
    return 0;
}

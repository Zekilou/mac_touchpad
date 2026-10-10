/*
 * probe6.c — 单参数扫描：每次只改一个参数，观察下发缓冲差异
 * 目的：界定「哪些参数真实进入波形」，为 UI 旋钮设计提供依据
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

#define FW "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
typedef CFTypeRef (*fnFromDict)(CFDictionaryRef, void *);
typedef int (*fnActAct)(CFTypeRef, void *, void *);
typedef void *(*fnCreate)(uint64_t);
typedef int (*fnOpen)(void *, int);
static CFNumberRef ni(int v){ return CFNumberCreate(NULL,kCFNumberIntType,&v); }
static CFNumberRef nd(double v){ return CFNumberCreate(NULL,kCFNumberDoubleType,&v); }

static CFDictionaryRef wave(const char *toneType, int baseDur, double baseAmp,
                            double freq, int toneDur, double toneAmp, int delay) {
    CFMutableDictionaryRef base = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(base, CFSTR("Type"), CFSTR("Gaussian"));
    CFDictionarySetValue(base, CFSTR("DurationMS"), ni(baseDur));
    CFDictionarySetValue(base, CFSTR("Amplitude"), nd(baseAmp));
    CFMutableDictionaryRef tone = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(tone, CFSTR("Type"), CFStringCreateWithCString(NULL,toneType,kCFStringEncodingUTF8));
    CFDictionarySetValue(tone, CFSTR("FrequencykHz"), nd(freq));
    CFDictionarySetValue(tone, CFSTR("Amplitude"), nd(toneAmp));
    CFDictionarySetValue(tone, CFSTR("DurationMS"), ni(toneDur));
    CFDictionarySetValue(tone, CFSTR("DelayMS"), ni(delay));
    CFArrayRef tones = CFArrayCreate(NULL,(const void**)&tone,1,&kCFTypeArrayCallBacks);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(d, CFSTR("BaseWaveform"), base);
    CFDictionarySetValue(d, CFSTR("Tones"), tones);
    return d;
}

int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    void *H = dlopen(FW, RTLD_LAZY);
    CFMutableArrayRef (*createList)(void)=dlsym(H,"MTDeviceCreateList");
    fnCreate create=dlsym(H,"MTActuatorCreateFromDeviceID");
    fnOpen open_=dlsym(H,"MTActuatorOpen");
    fnFromDict fromDict=dlsym(H,"MTActuationCreateFromDictionary");
    fnActAct actAct=dlsym(H,"MTActuationActuate");
    void *dev=(void*)CFArrayGetValueAtIndex(createList(),0);
    uint64_t devID=*(uint64_t*)((const char*)dev+64);
    void *a=create(devID); open_(a,0);

    /* 基线：Sine / baseDur6 / amp19 / freq1.18 / toneDur3 / toneAmp0.02 / delay0 */
    struct { const char *label; CFDictionaryRef w; } cs[5] = {
        {"1 baseline        ", wave("Sine",  6, 19, 1.18,  3, 0.02, 0)},
        {"2 baseAmp 19->35  ", wave("Sine",  6, 35, 1.18,  3, 0.02, 0)},
        {"3 freq 1.18->3.6  ", wave("Sine",  6, 19, 3.60,  3, 0.02, 0)},
        {"4 toneDur 3->20   ", wave("Sine",  6, 19, 1.18, 20, 0.02, 0)},
        {"5 baseDur 6->40   ", wave("Sine", 40, 19, 1.18,  3, 0.02, 0)},
    };
    for (int i=0;i<5;i++){
        CFTypeRef act = fromDict(cs[i].w, NULL);
        printf("CASE %s actuation=%p rc=%d\n", cs[i].label, act, act?actAct(act,a,NULL):-99);
        usleep(300000);
    }
    return 0;
}

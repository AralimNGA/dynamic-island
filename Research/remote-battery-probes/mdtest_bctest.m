// bctest.m - READ-ONLY probe of BatteryCenter.framework (no BT scanning started by us).
// Build: clang -fobjc-arc -framework Foundation -o bctest bctest.m
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

@interface Obs : NSObject
@end
@implementation Obs
- (void)connectedDevicesDidChange:(NSArray *)devs { printf("[observer] connectedDevicesDidChange: %lu\n", (unsigned long)devs.count); fflush(stdout); }
@end

static void dumpMethods(Class c, BOOL meta) {
    unsigned n = 0;
    Method *m = class_copyMethodList(meta ? object_getClass(c) : c, &n);
    printf("  %s methods (%u):", meta ? "class" : "instance", n);
    for (unsigned i = 0; i < n; i++) printf(" %s%s", meta ? "+" : "-", sel_getName(method_getName(m[i])));
    printf("\n");
    free(m);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        const char *p = argc > 1 ? argv[1] : "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter";
        void *h = dlopen(p, RTLD_NOW);
        printf("dlopen %s -> %s\n", p, h ? "OK" : dlerror());
        Class C = NSClassFromString(@"BCBatteryDeviceController");
        printf("BCBatteryDeviceController=%p\n", C);
        if (!C) return 1;
        dumpMethods(C, YES);
        dumpMethods(C, NO);
        Class D = NSClassFromString(@"BCBatteryDevice");
        if (D) dumpMethods(D, NO);
        id ctl = ((id (*)(id, SEL))objc_msgSend)(C, sel_registerName("_sharedPowerSourceController"));
        printf("_sharedPowerSourceController=%p %s\n", ctl, [[ctl description] UTF8String]); if (!ctl) ctl = [[C alloc] init];
        Obs *o = [Obs new];
        SEL addObs = sel_registerName("addBatteryDeviceObserver:queue:");
        if ([ctl respondsToSelector:addObs])
            ((void (*)(id, SEL, id, id))objc_msgSend)(ctl, addObs, o, dispatch_get_main_queue());
        for (int t = 0; t < 4; t++) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
            NSArray *devs = [ctl valueForKey:@"connectedDevices"];
            printf("t=%ds connectedDevices=%lu\n", (t + 1) * 2, (unsigned long)devs.count);
            for (id d in devs) {
                printf("  - %s\n", [[d description] UTF8String]);
            }
        }
    }
    return 0;
}

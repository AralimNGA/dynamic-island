// mdtest.m - READ-ONLY probe of MobileDevice.framework (no pairing, no writes).
// Build: clang -fobjc-arc -framework Foundation -o mdtest mdtest.m
// Run:   ./mdtest [seconds]
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef struct am_device *AMDeviceRef;
struct am_device_notification_callback_info {
    AMDeviceRef dev;
    unsigned int msg;   // 1 = connected, 2 = disconnected, 3 = unsubscribed
};
typedef void (*am_notify_cb)(struct am_device_notification_callback_info *, void *);

static int (*p_Subscribe)(am_notify_cb, unsigned int, unsigned int, void *, void **);
static int (*p_SubscribeWithOptions)(am_notify_cb, unsigned int, unsigned int, void *, void **, CFDictionaryRef);
static CFStringRef (*p_CopyDeviceIdentifier)(AMDeviceRef);
static int (*p_GetInterfaceType)(AMDeviceRef);
static int (*p_Connect)(AMDeviceRef);
static int (*p_Disconnect)(AMDeviceRef);
static int (*p_IsPaired)(AMDeviceRef);
static int (*p_ValidatePairing)(AMDeviceRef);
static int (*p_StartSession)(AMDeviceRef);
static int (*p_StopSession)(AMDeviceRef);
static CFTypeRef (*p_CopyValue)(AMDeviceRef, CFStringRef, CFStringRef);
static AMDeviceRef (*p_Retain)(AMDeviceRef);

static NSMutableSet *seen;

static NSString *ifname(int t) {
    switch (t) {
        case 0: return @"unknown(0)";
        case 1: return @"USB(1)";
        case 2: return @"network/WiFi(2)";
        case 3: return @"companion-proxy(3)";
        default: return [NSString stringWithFormat:@"other(%d)", t];
    }
}

static id cv(AMDeviceRef d, NSString *domain, NSString *key) {
    CFTypeRef v = p_CopyValue(d, (__bridge CFStringRef)domain, (__bridge CFStringRef)key);
    return v ? CFBridgingRelease(v) : nil;
}

static void probe(AMDeviceRef d) {
    CFStringRef cid = p_CopyDeviceIdentifier(d);
    NSString *udid = cid ? CFBridgingRelease(cid) : @"(nil)";
    int itype = p_GetInterfaceType(d);
    NSString *keyseen = [NSString stringWithFormat:@"%@|%d", udid, itype];
    if ([seen containsObject:keyseen]) return;
    [seen addObject:keyseen];

    printf("\n=== device %s  interface=%s\n", udid.UTF8String, ifname(itype).UTF8String);
    int rc = p_Connect(d);
    printf("  AMDeviceConnect rc=0x%x\n", rc);
    if (rc != 0) return;

    // Unauthenticated lockdown values (no session needed)
    NSString *name = cv(d, nil, @"DeviceName");
    NSString *ptype = cv(d, nil, @"ProductType");
    NSString *dclass = cv(d, nil, @"DeviceClass");
    NSString *pver = cv(d, nil, @"ProductVersion");
    printf("  DeviceName=%s ProductType=%s DeviceClass=%s ProductVersion=%s\n",
           [[name description] UTF8String], [[ptype description] UTF8String],
           [[dclass description] UTF8String], [[pver description] UTF8String]);

    int paired = p_IsPaired(d);
    printf("  AMDeviceIsPaired=%d\n", paired);
    if (!paired) {
        printf("  NOT paired with this Mac -> skipping (no pairing attempted)\n");
        p_Disconnect(d);
        return;
    }
    rc = p_ValidatePairing(d);
    printf("  AMDeviceValidatePairing rc=0x%x\n", rc);
    if (rc != 0) { p_Disconnect(d); return; }
    rc = p_StartSession(d);
    printf("  AMDeviceStartSession rc=0x%x\n", rc);
    if (rc == 0) {
        id cap = cv(d, @"com.apple.mobile.battery", @"BatteryCurrentCapacity");
        id chg = cv(d, @"com.apple.mobile.battery", @"BatteryIsCharging");
        id all = cv(d, @"com.apple.mobile.battery", nil);
        printf("  battery.BatteryCurrentCapacity=%s\n", [[cap description] UTF8String]);
        printf("  battery.BatteryIsCharging=%s\n", [[chg description] UTF8String]);
        printf("  battery.(whole domain)=%s\n", [[all description] UTF8String]);
        p_StopSession(d);
    }
    p_Disconnect(d);
}

static void cb(struct am_device_notification_callback_info *info, void *ctx) {
    const char *m = info->msg == 1 ? "CONNECTED" : info->msg == 2 ? "DISCONNECTED" : "OTHER";
    printf("[notify] msg=%u (%s) dev=%p\n", info->msg, m, info->dev);
    fflush(stdout);
    if (info->msg == 1) {
        AMDeviceRef d = info->dev;
        p_Retain(d);
        dispatch_async(dispatch_get_main_queue(), ^{ probe(d); fflush(stdout); });
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 8.0;
        const char *paths[] = {
            "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        };
        void *h = NULL;
        for (int i = 0; i < 2 && !h; i++) {
            h = dlopen(paths[i], RTLD_NOW);
            printf("dlopen %s -> %s\n", paths[i], h ? "OK" : dlerror());
        }
        if (!h) return 1;
#define L(v, s) v = dlsym(h, s); if (!v) { printf("missing %s\n", s); return 2; }
        L(p_Subscribe, "AMDeviceNotificationSubscribe");
        L(p_SubscribeWithOptions, "AMDeviceNotificationSubscribeWithOptions");
        L(p_CopyDeviceIdentifier, "AMDeviceCopyDeviceIdentifier");
        L(p_GetInterfaceType, "AMDeviceGetInterfaceType");
        L(p_Connect, "AMDeviceConnect");
        L(p_Disconnect, "AMDeviceDisconnect");
        L(p_IsPaired, "AMDeviceIsPaired");
        L(p_ValidatePairing, "AMDeviceValidatePairing");
        L(p_StartSession, "AMDeviceStartSession");
        L(p_StopSession, "AMDeviceStopSession");
        L(p_CopyValue, "AMDeviceCopyValue");
        L(p_Retain, "AMDeviceRetain");
        seen = [NSMutableSet set];

        // Include network devices that are already paired with this Mac. We deliberately
        // do NOT set NotificationOptionSearchForWiFiPairableDevices (would list unpaired, pairable devices).
        NSDictionary *opts = @{
            @"NotificationOptionSearchForPairedDevices": @YES,
            @"NotificationOptionEnableUSBMux": @YES,
            @"NotificationOptionEnableRemoteXPC": @YES,
        };
        void *notif = NULL;
        int rc;
        if (argc > 2 && strcmp(argv[2], "plain") == 0) {
            rc = p_Subscribe(cb, 0, 0, NULL, &notif);
            printf("AMDeviceNotificationSubscribe (plain, default options) rc=0x%x notif=%p (waiting %.0fs)\n", rc, notif, secs);
        } else {
            rc = p_SubscribeWithOptions(cb, 0, 0, NULL, &notif, (__bridge CFDictionaryRef)opts);
            printf("AMDeviceNotificationSubscribeWithOptions %s rc=0x%x notif=%p (waiting %.0fs)\n", opts.description.UTF8String, rc, notif, secs);
        }
        fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        printf("\ndone, %lu distinct device/interface entries seen\n", (unsigned long)seen.count);
    }
    return 0;
}

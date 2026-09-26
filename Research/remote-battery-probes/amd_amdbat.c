// Read-only probe: enumerate devices known to MobileDevice, read battery domain for paired ones.
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

typedef struct am_device *AMDeviceRef;
typedef struct am_device_notification *AMDeviceNotificationRef;
typedef struct {
    AMDeviceRef dev;          // offset 0
    uint32_t msg;             // offset 8  (1 connected, 2 disconnected, 3 unsubscribed)
    AMDeviceNotificationRef subscription; // offset 16
} am_device_notification_callback_info;
typedef void (*am_device_notification_callback)(am_device_notification_callback_info *, void *);

extern int AMDeviceNotificationSubscribeWithOptions(am_device_notification_callback cb, uint32_t u0, uint32_t u1, void *ctx, AMDeviceNotificationRef *out, CFDictionaryRef options);
extern int AMDeviceConnect(AMDeviceRef);
extern int AMDeviceIsPaired(AMDeviceRef);
extern int AMDeviceValidatePairing(AMDeviceRef);
extern int AMDeviceStartSession(AMDeviceRef);
extern int AMDeviceStopSession(AMDeviceRef);
extern int AMDeviceDisconnect(AMDeviceRef);
extern CFTypeRef AMDeviceCopyValue(AMDeviceRef, CFStringRef domain, CFStringRef key);
extern CFStringRef AMDeviceCopyDeviceIdentifier(AMDeviceRef);
extern int AMDeviceGetInterfaceType(AMDeviceRef);
extern AMDeviceRef AMDeviceCopyPairedCompanion(AMDeviceRef);
extern AMDeviceRef AMDeviceRetain(AMDeviceRef);
extern void AMDeviceRelease(AMDeviceRef);

static void show(const char *label, CFTypeRef v) {
    if (!v) { printf("  %s: (null)\n", label); return; }
    CFStringRef d = CFCopyDescription(v);
    char buf[4096]; CFStringGetCString(d, buf, sizeof buf, kCFStringEncodingUTF8);
    printf("  %s: %s\n", label, buf); CFRelease(d);
}

static void cb(am_device_notification_callback_info *info, void *ctx) {
    printf("msg=%u offsetof(msg)=%zu\n", info->msg, offsetof(am_device_notification_callback_info, msg));
    if (info->msg != 1) return;
    AMDeviceRef d = info->dev;
    CFStringRef udid = AMDeviceCopyDeviceIdentifier(d);
    int itype = AMDeviceGetInterfaceType(d);
    char ub[128] = "?"; if (udid) CFStringGetCString(udid, ub, sizeof ub, kCFStringEncodingUTF8);
    printf("device %s interfaceType=%d\n", ub, itype);
    int rc = AMDeviceConnect(d);
    printf("  connect=0x%x paired=%d\n", rc, rc == 0 ? AMDeviceIsPaired(d) : -1);
    if (rc == 0) {
        show("DeviceClass(no session)", AMDeviceCopyValue(d, NULL, CFSTR("DeviceClass")));
        if (AMDeviceIsPaired(d)) {
            int v = AMDeviceValidatePairing(d); int s = v == 0 ? AMDeviceStartSession(d) : -1;
            printf("  validate=0x%x session=0x%x\n", v, s);
            if (s == 0) {
                show("DeviceName", AMDeviceCopyValue(d, NULL, CFSTR("DeviceName")));
                show("battery", AMDeviceCopyValue(d, CFSTR("com.apple.mobile.battery"), NULL));
                AMDeviceStopSession(d);
            }
        }
        AMDeviceDisconnect(d);
    }
    if (udid) CFRelease(udid);
    fflush(stdout);
}

int main(int argc, char **argv) {
    const void *k[] = { CFSTR("NotificationOptionSearchForPairedDevices") };
    const void *v[] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    AMDeviceNotificationRef n = NULL;
    int rc = AMDeviceNotificationSubscribeWithOptions(cb, 0, 0, NULL, &n, opts);
    printf("subscribe rc=0x%x\n", rc); fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, argc > 1 ? atof(argv[1]) : 10.0, false);
    printf("done\n");
    return 0;
}

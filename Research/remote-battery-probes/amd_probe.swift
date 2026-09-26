import Foundation

// Dynamic binding to MobileDevice.framework (private, Apple-signed; passes hardened-runtime library validation).
let md = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW)!
func sym<T>(_ n: String, _: T.Type) -> T { unsafeBitCast(dlsym(md, n)!, to: T.self) }

typealias AMDeviceRef = UnsafeMutableRawPointer
// am_device_notification_callback_info (arm64): +0 AMDeviceRef device, +8 uint32 msg, +16 AMDeviceNotificationRef subscription
typealias Callback = @convention(c) (UnsafeRawPointer, UnsafeMutableRawPointer?) -> Void
let subscribe = sym("AMDeviceNotificationSubscribeWithOptions",
    (@convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>, CFDictionary?) -> Int32).self)
let connect   = sym("AMDeviceConnect", (@convention(c) (AMDeviceRef) -> Int32).self)
let isPaired  = sym("AMDeviceIsPaired", (@convention(c) (AMDeviceRef) -> Int32).self)
let validate  = sym("AMDeviceValidatePairing", (@convention(c) (AMDeviceRef) -> Int32).self)
let startSess = sym("AMDeviceStartSession", (@convention(c) (AMDeviceRef) -> Int32).self)
let stopSess  = sym("AMDeviceStopSession", (@convention(c) (AMDeviceRef) -> Int32).self)
let disconnect = sym("AMDeviceDisconnect", (@convention(c) (AMDeviceRef) -> Int32).self)
let copyValue = sym("AMDeviceCopyValue", (@convention(c) (AMDeviceRef, CFString?, CFString?) -> Unmanaged<CFTypeRef>?).self)
let copyID    = sym("AMDeviceCopyDeviceIdentifier", (@convention(c) (AMDeviceRef) -> Unmanaged<CFString>?).self)
let ifType    = sym("AMDeviceGetInterfaceType", (@convention(c) (AMDeviceRef) -> Int32).self)

let cb: Callback = { info, _ in
    let msg = info.load(fromByteOffset: 8, as: UInt32.self)
    let dev = info.load(fromByteOffset: 0, as: UnsafeMutableRawPointer?.self)
    print("msg:", msg)
    guard msg == 1, let d = dev else { return }
    let udid = copyID(d)?.takeRetainedValue() as String? ?? "?"
    print("device", udid, "iface", ifType(d))            // 1 USB, 2 Wi-Fi, 3 proxied (Watch via iPhone)
    guard connect(d) == 0 else { return }
    defer { _ = disconnect(d) }
    guard isPaired(d) != 0, validate(d) == 0, startSess(d) == 0 else { print("not paired / session failed"); return }
    defer { _ = stopSess(d) }
    let battery = copyValue(d, "com.apple.mobile.battery" as CFString, nil)?.takeRetainedValue() as? [String: Any]
    print("battery:", battery ?? [:])  // BatteryCurrentCapacity (Int 0-100), BatteryIsCharging (Bool), ExternalConnected, FullyCharged ...
}
var note: UnsafeMutableRawPointer?
let opts = ["NotificationOptionSearchForPairedDevices": true] as CFDictionary
print("subscribe rc:", subscribe(cb, 0, 0, nil, &note, opts))
RunLoop.main.run(until: Date().addingTimeInterval(5))
print("done")

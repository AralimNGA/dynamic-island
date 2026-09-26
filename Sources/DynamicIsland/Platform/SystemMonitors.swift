import AppKit
import CoreAudio
import CoreMediaIO

/// Kamera-/Mikrofon-Indikator wie der grüne/orange Punkt auf dem iPhone:
/// meldet, ob eine andere App gerade Kamera oder Mikrofon benutzt.
final class PrivacyMonitor {
    struct Usage: Equatable {
        var camera = false
        var mic = false
        var any: Bool { camera || mic }
    }

    /// Wird auf dem Main-Thread bei jeder Änderung gerufen.
    var onChange: ((Usage) -> Void)?
    /// Eigene Nutzung (Spiegel-Tab, Aufnahme) herausrechnen.
    var ownCameraInUse: () -> Bool = { false }
    var ownMicInUse: () -> Bool = { false }

    private(set) var usage = Usage()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "island.privacy", qos: .utility)

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let ownCam = ownCameraInUse(), ownMic = ownMicInUse()
        queue.async { [weak self] in
            let cam = !ownCam && Self.anyCameraRunning()
            let mic = !ownMic && AudioMonitor.isRunningSomewhere(AudioMonitor.defaultInputDevice())
            let next = Usage(camera: cam, mic: mic)
            DispatchQueue.main.async {
                guard let self, next != self.usage else { return }
                self.usage = next
                self.onChange?(next)
            }
        }
    }

    private static func anyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &devices) == noErr else { return false }

        for dev in devices {
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(dev, &runAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}

/// Bildschirm entsperrt → kurze „Face ID“-artige Bestätigung in der Island.
final class LockMonitor {
    var onUnlock: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []

    func start() {
        let dnc = DistributedNotificationCenter.default()
        tokens.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            // Kurz warten, bis der Schreibtisch wieder sichtbar ist.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.onUnlock?() }
        })
    }
}

/// Helligkeit des eingebauten Displays über das private DisplayServices-Framework
/// (per dlopen, damit die App auch ohne das Framework startet).
enum DisplayBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: GetFn.self)
    }()
    private static let setFn: SetFn? = {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()

    static var builtinDisplay: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    static func get() -> Double? {
        guard let getFn else { return nil }
        var v: Float = 0
        guard getFn(builtinDisplay, &v) == 0 else { return nil }
        return Double(v)
    }

    static func set(_ value: Double) {
        _ = setFn?(builtinDisplay, Float(min(1, max(0, value))))
    }
}

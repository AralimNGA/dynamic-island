import Foundation

/// iPhone/iPad-Akku über „Instant Hotspot“ – dieselben Daten, mit denen das
/// WLAN-Menü den Akku des iPhones zeigt. Privates `SFRemoteHotspotSession`
/// (Sharing.framework), ohne Entitlement und ohne Berechtigungsdialog (live
/// geprüft auf macOS 26.7). Nur grob: 20 / 50 / 75 / 100 %.
///
/// Es wird ausschliesslich *gesucht* (startBrowsing/stopBrowsing).
/// `enableHotspotForDevice:` wird NIE aufgerufen – das würde den Hotspot einschalten.
final class HotspotProvider: NSObject {
    var onSamples: (([BatterySample]) -> Void)?    // auf Main
    private(set) var isAvailable = true

    private var session: NSObject?
    private var stopWork: DispatchWorkItem?

    private static let loaded: Bool =
        dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil

    /// Kurzes Suchfenster (Main-Thread). Der Delegate ist in Sharing schwach –
    /// der Provider wird vom Dienst gehalten.
    func browse(window: TimeInterval = 12) {
        guard session == nil else { return }
        guard Self.loaded,
              let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type,
              cls.instancesRespond(to: NSSelectorFromString("startBrowsing")),
              cls.instancesRespond(to: NSSelectorFromString("stopBrowsing")),
              cls.instancesRespond(to: NSSelectorFromString("setDelegate:"))
        else {
            isAvailable = false
            return
        }
        let s = cls.init()
        s.setValue(self, forKey: "delegate")
        _ = s.perform(NSSelectorFromString("startBrowsing"))
        session = s
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        guard let s = session else { return }
        _ = s.perform(NSSelectorFromString("stopBrowsing"))
        s.setValue(nil, forKey: "delegate")
        session = nil
    }

    /// Kommt auf einer XPC-Queue von sharingd.
    @objc(session:updatedFoundDevices:)
    func session(_ session: AnyObject, updatedFoundDevices devices: NSArray) {
        let now = Date()
        var out: [BatterySample] = []
        for case let d as NSObject in devices {
            guard let name: String = d.safeValue("deviceName"),
                  let model: String = d.safeValue("model"),
                  let battery: NSNumber = d.safeValue("batteryLife") else { continue }
            // Eigene Geräte haben group 1 (Familie vermutlich anders) → nur eigene.
            if let group: NSNumber = d.safeValue("group"), group.intValue != 1 { continue }
            let pct = battery.intValue
            guard (1...100).contains(pct) else { continue }
            let cached = (d.safeValue("cachedDevice") as NSNumber?)?.boolValue ?? false
            let kind: DeviceKind = model.hasPrefix("iPad") ? .iPad : .iPhone
            out.append(BatterySample(
                key: RemoteDeviceKey(kind: kind, model: model, name: name),
                parts: [BatteryPart(slot: .main, percent: pct, charging: nil)],
                precision: .bucket4, source: .hotspot,
                // Aus dem Cache von sharingd: etwas älter einstufen.
                observedAt: cached ? now.addingTimeInterval(-60) : now))
        }
        guard !out.isEmpty else { return }
        DispatchQueue.main.async { self.onSamples?(out) }
    }
}

extension NSObject {
    /// KVC ohne die in Swift nicht abfangbare NSUnknownKeyException.
    func safeValue<T>(_ key: String) -> T? {
        guard responds(to: NSSelectorFromString(key)) else { return nil }
        return value(forKey: key) as? T
    }
}

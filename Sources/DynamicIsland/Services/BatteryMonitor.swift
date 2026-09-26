import Foundation
import IOKit.ps
import Combine

/// Live battery state via IOKit power sources (public API, no permissions needed).
final class BatteryMonitor: ObservableObject {
    @Published var percent: Int = 100
    @Published var isCharging = false
    @Published var isPluggedIn = false
    @Published var present = true
    @Published var timeToFull: Int = -1   // minutes, -1 = unknown

    /// Called when the AC adapter is connected/disconnected.
    var onPlugChange: ((_ pluggedIn: Bool) -> Void)?
    /// Called when the charge level changes (old, new) – für Akku-Warnungen.
    var onPercentChange: ((_ old: Int, _ new: Int) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var wasPlugged = false
    private var started = false

    func start() {
        update()
        wasPlugged = isPluggedIn
        guard !started else { return }
        started = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.update() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func update() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { present = false; return }

        let oldPercent = percent
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false

            percent = maxCap > 0 ? Int((Double(cur) / Double(maxCap) * 100).rounded()) : cur
            isPluggedIn = (state == kIOPSACPowerValue)
            isCharging = charging
            timeToFull = desc[kIOPSTimeToFullChargeKey] as? Int ?? -1
            present = true
            break
        }

        if started, percent != oldPercent { onPercentChange?(oldPercent, percent) }
        // Erst nach dem Start melden – sonst erscheint bei jedem App-Start „Laden“.
        if started, isPluggedIn != wasPlugged {
            wasPlugged = isPluggedIn
            onPlugChange?(isPluggedIn)
        }
    }
}

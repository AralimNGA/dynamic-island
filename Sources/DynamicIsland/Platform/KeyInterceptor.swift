import AppKit
import ApplicationServices

/// Event-Tap auf HID-Ebene (braucht „Bedienungshilfen“): Lautstärke- und
/// Helligkeitstasten zeigen das eigene HUD in der Island statt dem System-HUD.
final class KeyInterceptor {
    enum MediaKey { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    /// Rückgabe `true` = Taste wurde behandelt und wird geschluckt.
    var onMediaKey: ((_ key: MediaKey, _ fineStep: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeyUps = Set<Int>()

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Öffnet den Systemdialog „Bedienungshilfen erlauben“.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Self.isTrusted else { return false }
        let mask: CGEventMask = 1 << 14   // NX_SYSDEFINED (Medientasten)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let state = (data & 0xFF00) >> 8          // 0xA = gedrückt, 0xB = losgelassen
        guard let key = Self.mediaKey(code) else { return pass }

        if state == 0xA {
            let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
            if onMediaKey?(key, fine) == true {
                swallowedKeyUps.insert(code)
                return nil
            }
            return pass
        }
        if state == 0xB, swallowedKeyUps.remove(code) != nil { return nil }
        return pass
    }

    private static func mediaKey(_ code: Int) -> MediaKey? {
        switch code {
        case 0: return .volumeUp          // NX_KEYTYPE_SOUND_UP
        case 1: return .volumeDown        // NX_KEYTYPE_SOUND_DOWN
        case 7: return .mute              // NX_KEYTYPE_MUTE
        case 2: return .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: return .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        default: return nil
        }
    }
}

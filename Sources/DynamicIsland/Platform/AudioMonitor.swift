import Foundation
import CoreAudio
import AudioToolbox

/// Lautstärke, Stummschaltung und Ausgabegerät über CoreAudio (öffentliche API,
/// keine Berechtigung nötig). Meldet Änderungen – egal ob per Taste, Kontroll-
/// zentrum oder App – und kann die Lautstärke selbst setzen (für den HUD-Ersatz).
final class AudioMonitor {
    struct Output: Equatable {
        let id: AudioDeviceID
        let name: String
        let isBluetooth: Bool
    }

    /// (Lautstärke 0…1, stumm)
    var onVolumeChange: ((Double, Bool) -> Void)?
    /// Neues Standard-Ausgabegerät (nicht beim Start).
    var onOutputChange: ((Output) -> Void)?

    private(set) var output: Output?
    private var observedDevice: AudioDeviceID = 0
    private var suppressUntil = Date.distantPast
    private let listenerQueue = DispatchQueue.main

    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.volumeChanged()
    }
    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.defaultDeviceChanged()
    }

    func start() {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            listenerQueue, defaultDeviceListener)
        attach(to: Self.defaultOutputDevice(), announce: false)
    }

    // MARK: Lesen / Setzen

    var volume: Double {
        guard observedDevice != 0 else { return 0 }
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(observedDevice, &addr, 0, nil, &size, &v) == noErr else { return 0 }
        return Double(v)
    }

    var isMuted: Bool {
        guard observedDevice != 0 else { return false }
        var addr = Self.address(kAudioDevicePropertyMute)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(observedDevice, &addr, 0, nil, &size, &m) == noErr else { return false }
        return m != 0
    }

    /// Kann das aktuelle Gerät per Software geregelt werden? (HDMI-Monitore oft nicht)
    var canSetVolume: Bool {
        guard observedDevice != 0 else { return false }
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(observedDevice, &addr, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ value: Double) {
        guard observedDevice != 0 else { return }
        var addr = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(observedDevice, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if v > 0, isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard observedDevice != 0 else { return }
        var addr = Self.address(kAudioDevicePropertyMute)
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(observedDevice, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    // MARK: Intern

    private static let debug = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"

    private func volumeChanged() {
        if Self.debug { DebugHooks.log("‹audio› volume \(volume) muted \(isMuted) suppressed=\(Date() <= suppressUntil)") }
        guard Date() > suppressUntil else { return }
        onVolumeChange?(volume, isMuted)
    }

    private func defaultDeviceChanged() {
        attach(to: Self.defaultOutputDevice(), announce: true)
    }

    private func attach(to device: AudioDeviceID, announce: Bool) {
        guard device != observedDevice else { return }
        if observedDevice != 0 {
            for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var addr = Self.address(sel)
                AudioObjectRemovePropertyListenerBlock(observedDevice, &addr, listenerQueue, volumeListener)
            }
        }
        observedDevice = device
        guard device != 0 else { output = nil; return }
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var addr = Self.address(sel)
            AudioObjectAddPropertyListenerBlock(device, &addr, listenerQueue, volumeListener)
        }
        let out = Output(id: device, name: Self.name(of: device), isBluetooth: Self.isBluetooth(device))
        output = out
        // Ein Gerätewechsel meldet oft gleich noch eine Lautstärke – die nicht als HUD zeigen.
        suppressUntil = Date().addingTimeInterval(1.0)
        if announce { onOutputChange?(out) }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// Nutzt irgendein Prozess das Gerät gerade (Mikrofon-Indikator)?
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        guard device != 0 else { return false }
        var addr = address(kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func name(of device: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return "Ausgabe" }
        return cf as String
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Passendes SF-Symbol für ein Audiogerät.
    static func symbol(forDevice name: String, bluetooth: Bool) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("macbook") || n.contains("lautsprecher") || n.contains("speaker") { return "laptopcomputer" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("display") || n.contains("hdmi") || n.contains("monitor") { return "display" }
        return bluetooth ? "headphones" : "hifispeaker.fill"
    }
}

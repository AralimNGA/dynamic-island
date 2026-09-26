import AppKit
import Combine
import CoreBluetooth

/// Koordiniert die Quellen für Akkustände deiner anderen Apple-Geräte:
/// - Instant Hotspot (iPhone/iPad, grob, ohne Einrichtung)
/// - AirPods-Bluetooth-Signal (auch wenn die AirPods am iPhone hängen)
/// - Kabel-Kopplung / WLAN-Sync (iPhone/iPad genau, Apple Watch über das iPhone)
/// Alle Werte kommen direkt von Geräten in der Nähe, nicht aus iCloud.
final class RemoteBatteryService: ObservableObject {
    enum BluetoothState { case off, notDetermined, denied, enabled }

    let store = RemoteBatteryStore()
    @Published private(set) var bluetoothState: BluetoothState = .off
    @Published private(set) var lockdownStatus: [String: LockdownStatus] = [:]

    private let hotspot = HotspotProvider()
    private let scanner = ProximityPairingScanner()
    private let lockdown = LockdownProvider()
    private weak var deviceBattery: DeviceBatteryService?
    private var timers: [Timer] = []
    private var bag = Set<AnyCancellable>()
    private var asleep = false
    private var lastBrowse = Date.distantPast
    private var started = false

    private var settings: AppSettings { .shared }

    init(deviceBattery: DeviceBatteryService) {
        self.deviceBattery = deviceBattery
        scanner.debugRaw = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    }

    func start() {
        guard !started else { return }
        started = true

        hotspot.onSamples = { [weak self] list in self?.store.ingest(list) }
        scanner.onSample = { [weak self] s in self?.store.ingest(s) }
        lockdown.onSample = { [weak self] s in self?.store.ingest(s) }
        lockdown.onStatus = { [weak self] name, status in self?.lockdownStatus[name] = status }
        scanner.onStateChange = { [weak self] in self?.updateBluetoothState() }

        // Geräte-Tab ausgeblendet → gar nicht erst im Hintergrund abfragen (Energie).
        settings.$enabledTabs
            .map { $0.contains(ExpandedTab.devices.rawValue) }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                self?.applySettings()
                if on { self?.refreshAll(force: true) }
            }
            .store(in: &bag)

        // Gekoppelte AirPods → „gehört mir“-Liste für den Scanner.
        deviceBattery?.$pairedAudio
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.scanner.owned = list }
            .store(in: &bag)
        deviceBattery?.refresh()

        updateBluetoothState()
        if devicesTabOn, settings.remoteBatteryBLE { scanner.enable() }      // fragt nur, wenn schon erlaubt/gewünscht
        if devicesTabOn, settings.remoteBatteryLockdown { lockdown.start() }

        // Takt (siehe Recherche): Hotspot 5 Min, AirPods 60 s, Kabel-Kopplung 5 Min.
        schedule(every: 300) { [weak self] in self?.browseHotspot() }
        schedule(every: 60) { [weak self] in self?.scanAirPods() }
        schedule(every: 300) { [weak self] in self?.pollLockdown() }
        schedule(every: 60) { [weak self] in self?.store.refreshAges() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.browseHotspot() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.hotspot.stop()
            self?.scanner.stop()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.refreshAll(force: true) }
        }
    }

    /// Geräte-Tab geöffnet → alles sofort auffrischen (Hotspot höchstens jede Minute).
    func refreshAll(force: Bool = false) {
        updateBluetoothState()
        browseHotspot(force: force)
        scanAirPods(seconds: 8)
        pollLockdown()
        store.refreshAges()
    }

    /// Knopf „Bluetooth erlauben“: löst die einmalige macOS-Abfrage aus.
    func enableBluetooth() {
        settings.remoteBatteryBLE = true
        scanner.enable()
        // Die Antwort auf den Systemdialog meldet der Scanner über onStateChange;
        // zusätzlich kurz nachprüfen (falls der Dialog gar nicht erschien).
        for delay in [1.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateBluetoothState() }
        }
    }

    /// Einstellungen geändert.
    func applySettings() {
        updateBluetoothState()
        let on = devicesTabOn
        if on && settings.remoteBatteryLockdown {
            lockdown.start()
        } else {
            lockdown.stop()
            lockdownStatus = [:]
        }
        if on && settings.remoteBatteryBLE { scanner.enable() } else { scanner.stop() }   // enable() prüft Freigabe selbst
        if !on || !settings.remoteBatteryHotspot { hotspot.stop() }
    }

    /// Ohne sichtbaren Geräte-Tab braucht niemand die Werte.
    private var devicesTabOn: Bool { settings.isEnabled(.devices) }

    // MARK: Intern

    private func schedule(every seconds: TimeInterval, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: seconds, repeats: true) { _ in block() }
        t.tolerance = seconds * 0.2
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func browseHotspot(force: Bool = false) {
        guard devicesTabOn, settings.remoteBatteryHotspot, !asleep else { return }
        guard force || Date().timeIntervalSince(lastBrowse) > 60 else { return }
        lastBrowse = Date()
        hotspot.browse(window: 12)
    }

    private func scanAirPods(seconds: Double = 6) {
        updateBluetoothState()
        guard devicesTabOn, settings.remoteBatteryBLE, !asleep, bluetoothState == .enabled else { return }
        scanner.scanWindow(seconds: seconds)
    }

    private func pollLockdown() {
        guard devicesTabOn, settings.remoteBatteryLockdown, !asleep else { return }
        lockdown.pollNow()
    }

    private func updateBluetoothState() {
        let next: BluetoothState
        switch ProximityPairingScanner.authorization {
        case .allowedAlways: next = settings.remoteBatteryBLE ? .enabled : .off
        case .denied, .restricted: next = .denied
        case .notDetermined: next = settings.remoteBatteryBLE ? .notDetermined : .off
        @unknown default: next = .off
        }
        guard next != bluetoothState else { return }
        let becameEnabled = next == .enabled
        bluetoothState = next
        // Freigabe kam gerade (auch spät) → Scanner sicher aktiv (fragt dabei nie nach).
        if becameEnabled, devicesTabOn { scanner.enable() }
    }
}

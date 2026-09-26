import Foundation

/// Ergebnis eines Leseversuchs pro Gerät (für Hinweise in der Oberfläche).
enum LockdownStatus: Equatable {
    case notTrusted      // Gerät vertraut diesem Mac (noch) nicht – einmal per Kabel „Vertrauen“ tippen
    case sessionFailed   // Verbindung oder Sitzung klappte nicht (Gerät schläft, WLAN weg …)
    case ok
}

/// Exakter Akkustand von iPhone und iPad über die bestehende Kopplung dieses Macs
/// (Kabel oder WLAN) – privates MobileDevice.framework, per dlopen geladen, damit die
/// App auch ohne das Framework startet. Dazu die Apple Watch über den Dienst
/// `com.apple.companion_proxy` des iPhones (auf der Uhr selbst ist nichts nötig).
///
/// Nur lesen: Es wird NIE gekoppelt, vertraut oder auf dem Gerät etwas gesetzt
/// (kein AMDevicePair, kein AMDeviceSetValue). Ist ein Gerät nicht vertraut, meldet
/// der Provider `.notTrusted` und lässt es danach in Ruhe.
///
/// Threads:
/// - Geräte-Meldungen: eigener Thread mit eigener CFRunLoop. Der Callback hält das
///   Gerät nur fest (Retain) und gibt es an die Zustands-Queue weiter.
/// - Buchhaltung (bekannte Geräte, laufende Abfragen): serielle Zustands-Queue.
/// - Die eigentlichen, blockierenden MobileDevice-Aufrufe: Arbeits-Queue, ein Auftrag
///   pro Gerät – nie auf Main und nie auf dem Meldungs-Thread. Hängt ein Gerät, blockiert
///   es die anderen nicht; ein Wachhund erlaubt nach 30 s (Wachzeit, ohne Ruhezustand)
///   genau einen weiteren Versuch, danach wird das Gerät ausgelassen, bis MobileDevice die
///   hängenden Aufrufe zurückgibt. Andere Geräte bleiben davon unberührt.
/// - Ergebnisse (`onSample`, `onStatus`) kommen auf Main.
final class LockdownProvider {
    var onSample: ((BatterySample) -> Void)?                              // auf Main
    var onStatus: ((_ name: String, _ status: LockdownStatus) -> Void)?   // auf Main
    /// MobileDevice.framework und alle nötigen Symbole geladen.
    private(set) var isAvailable: Bool

    private let engine: Engine?
    private let loopLock = NSLock()
    private var loop: NotifyLoop?          // nur unter loopLock

    init() {
        let api = API.shared
        isAvailable = api != nil
        engine = api.map { Engine(api: $0) }
        engine?.provider = self
    }

    deinit { stop() }

    /// Meldet sich für Geräte-Meldungen an (eigener Thread mit CFRunLoop). Mehrfach aufrufbar.
    func start() {
        guard let engine else { return }
        loopLock.lock()
        defer { loopLock.unlock() }
        if let current = loop, !current.failed { return }
        let newLoop = NotifyLoop()
        loop = newLoop
        engine.setRunning(true)
        let api = engine.api, box = engine.callbackBox, lock = loopLock
        let thread = Thread {
            LockdownProvider.runNotificationLoop(api: api, box: box, loop: newLoop, lock: lock)
        }
        thread.name = "island.lockdown.notify"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Meldet sich ab und gibt alle gehaltenen Geräte frei. Laufende Abfragen enden von
    /// selbst, ihre Ergebnisse werden verworfen.
    func stop() {
        loopLock.lock()
        let current = loop
        loop = nil
        current?.cancelled = true
        let runLoop = current?.runLoop, note = current?.note
        current?.runLoop = nil
        current?.note = nil
        loopLock.unlock()

        guard let engine else { return }
        if let runLoop {
            // Abmelden auf dem Meldungs-Thread selbst, danach dessen Schleife beenden.
            let unsubscribe = engine.api.unsubscribe
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                if let note { _ = unsubscribe?(note) }
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        engine.setRunning(false)
    }

    /// Liest alle bekannten Geräte neu (im Hintergrund). Geräte mit laufender Abfrage
    /// werden übersprungen, ebenso solche, die eben erst gelesen wurden.
    func pollNow() { engine?.pollAll() }

    // MARK: Einstellungen

    /// Zeitbudget pro Gerät (lockdown). Ein blockierender C-Aufruf lässt sich nicht
    /// abbrechen – geprüft wird zwischen den Schritten; den Rest fängt der Wachhund.
    /// Budgets und Wachhund laufen auf der monotonen Uhr (`uptime()`), damit der
    /// Ruhezustand des Macs keine Abfrage künstlich „alt“ macht.
    private static let deviceBudget: TimeInterval = 10
    /// Zusätzliches Budget für die Uhr (companion_proxy), inkl. Socket-Zeitlimit.
    private static let watchBudget: TimeInterval = 15
    /// Wachhund: Eine Abfrage, die länger läuft, gilt als hängend und blockiert nicht mehr.
    private static let hungAfter: TimeInterval = 30
    /// Anmelde-Meldungen flattern im WLAN – so lange nach dem letzten Lesen nicht neu lesen.
    private static let attachDebounce: TimeInterval = 60
    /// pollNow() kurz nacheinander (z. B. Tab mehrmals geöffnet) → nicht doppelt lesen.
    private static let pollDebounce: TimeInterval = 15
    /// Die Uhr höchstens so oft über das iPhone abfragen.
    private static let watchInterval: TimeInterval = 600
    /// Pro Gerät höchstens so viele offene Aufträge: der hängende plus ein Wachhund-Versuch.
    /// MobileDevice reiht alle Aufrufe eines Geräts hinter einem Mutex auf – mehr Aufträge
    /// würden nur hinter dem hängenden warten.
    private static let maxJobsPerDevice = 2
    /// Obergrenze verschiedener Geräte mit offenen Aufträgen – begrenzt die Threads
    /// (höchstens maxBusyDevices × maxJobsPerDevice). Ein hängendes Gerät belegt nur einen Platz.
    private static let maxBusyDevices = 6
    /// Nur die geprüften Wege: 1 = Kabel, 2 = WLAN. Laut Tabelle hinter AMDeviceGetInterfaceType
    /// (macOS 26.7: intern {0,1,2,3} → {2,1,3,4}) gibt es noch 3 = über das iPhone durchgereichte
    /// Uhr (bräuchte Vertrauen der Uhr) und 4 = RemotePairing/RSD (StartSession baut dort einen
    /// CoreDevice-Tunnel auf, ungetestet) sowie -1 = unbekannt → alles auslassen.
    private static let supportedInterfaces: Set<Int32> = [1, 2]
    /// StartSession-Fehler, die wirklich „nicht vertraut“ bedeuten (AMDCopyErrorText, macOS 26.7):
    /// 0xe8000025 „host is not paired“ (kein Kopplungs-Datensatz – dann wird nichts gesendet),
    /// 0xe800001b/0xe800001c „device does not recognize this host“ (Vertrauen auf dem Gerät
    /// zurückgesetzt), 0xe800005c „no longer paired“. Alles andere – Zeitüberschreitung
    /// (0xe800000c), gesperrt vor dem ersten Entsperren (0xe800001a), beschäftigt (0xe8000011),
    /// getrennt (0xe8000084) … – ist vorübergehend und wird `.sessionFailed`.
    private static let notTrustedCodes: Set<UInt32> = [0xe800_0025, 0xe800_001b, 0xe800_001c, 0xe800_005c]
    private static let companionService = "com.apple.companion_proxy"
    private static let binaryPlist = CFPropertyListFormat.binaryFormat_v1_0.rawValue

    // MARK: Meldungs-Thread

    private static func runNotificationLoop(api: API, box: CallbackBox, loop: NotifyLoop, lock: NSLock) {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        // Ohne Quelle kehrt CFRunLoopRun sofort zurück – ein Platzhalter-Timer hält die
        // Schleife am Leben, egal wie MobileDevice seine Meldungen zustellt.
        let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                                                        CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, CFRunLoopMode.defaultMode)
        defer { CFRunLoopRemoveTimer(runLoop, keepAlive, CFRunLoopMode.defaultMode) }

        // Nur bereits gekoppelte Geräte (auch im WLAN). Bewusst NICHT
        // „SearchForWiFiPairableDevices“ – das listet fremde, koppelbare Geräte.
        var note: UnsafeMutableRawPointer?
        let options = ["NotificationOptionSearchForPairedDevices": true] as CFDictionary
        let rc = api.subscribe(notificationCallback, 0, 0,
                               Unmanaged.passUnretained(box).toOpaque(), &note, options)

        lock.lock()
        let cancelled = loop.cancelled
        if rc != 0 {
            loop.failed = true
        } else if !cancelled {
            loop.runLoop = runLoop
            loop.note = note
        }
        lock.unlock()

        guard rc == 0 else {
            log("Anmeldung fehlgeschlagen rc=\(hex(rc))")
            return
        }
        if cancelled {                      // stop() kam dazwischen
            if let note { _ = api.unsubscribe?(note) }
            return
        }
        log("angemeldet")
        CFRunLoopRun()
        log("abgemeldet")
    }

    /// C-Callback von MobileDevice. Layout (arm64, im Probe geprüft): +0 Gerät,
    /// +8 Meldung (1 angeschlossen, 2 getrennt, 3 abgemeldet, 4 gekoppelt).
    private static let notificationCallback: API.NotifyCallback = { info, context in
        guard let info, let context else { return }
        let message = info.load(fromByteOffset: 8, as: UInt32.self)
        guard message == 1 || message == 2 || message == 4,
              let device = info.load(fromByteOffset: 0, as: UnsafeMutableRawPointer?.self),
              let engine = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue().engine
        else { return }
        engine.notified(device: device, message: message)
    }

    // MARK: Hilfen

    fileprivate static func kind(deviceClass: String?, productType: String?) -> DeviceKind? {
        let probe = deviceClass ?? productType ?? ""
        if probe.hasPrefix("iPhone") { return .iPhone }
        if probe.hasPrefix("iPad") { return .iPad }
        return nil                          // iPod, Apple TV …: nicht unterstützt
    }

    fileprivate static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    fileprivate static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    fileprivate static func hex(_ rc: Int32) -> String {
        String(format: "0x%08x", UInt32(bitPattern: rc))
    }

    /// Monotone Uhr in Sekunden: läuft nur, solange der Mac wach ist (anders als `Date()`).
    fileprivate static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static let debug = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"

    fileprivate static func log(_ s: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("‹lockdown› " + s() + "\n").utf8))
    }
}

// MARK: - Interne Typen

private extension LockdownProvider {
    typealias DeviceRef = UnsafeMutableRawPointer
    typealias ServiceRef = UnsafeMutableRawPointer

    /// Zustand des Meldungs-Threads, geschützt durch `loopLock`.
    final class NotifyLoop {
        var runLoop: CFRunLoop?
        var note: UnsafeMutableRawPointer?
        var cancelled = false
        var failed = false
    }

    /// Kontext des C-Callbacks: nur ein schwacher Verweis, damit eine verspätete Meldung
    /// nie auf ein freigegebenes Objekt trifft.
    final class CallbackBox {
        weak var engine: Engine?
    }

    struct WatchInfo {
        let name: String
        let model: String
    }

    struct StatusMark: Equatable {
        let status: LockdownStatus
        let name: String
    }

    enum Trigger { case attach, paired, poll }

    struct Job {
        let udid: String
        let generation: Int
        let epoch: Int
        let wantWatch: Bool
        let knownWatches: [String: WatchInfo]
        var tag: String { String(udid.prefix(8)) }
    }

    struct ReadResult {
        var status: LockdownStatus?         // nil = nichts melden (z. B. Apple TV)
        var name: String?
        var samples: [BatterySample] = []
        var watchChecked = false
        var watchInfo: [String: WatchInfo] = [:]
    }

    /// Antwort auf GetValueFromRegistry.
    enum RegistryReply {
        case value(Any)
        case unsupported                    // „UnsupportedWatchKey“ (oder Schlüssel fehlt)
        case noAnswer                       // „TimeoutReply“ u. ä.: Uhr schläft oder ist weg
        case broken                         // Verbindung kaputt oder Zeit um → abbrechen

        /// Text für Name/Modell: Wert, Ersatz bei „nicht unterstützt“, sonst nil (später nochmals).
        func text(fallback: String) -> String? {
            switch self {
            case .value(let v):
                guard let s = v as? String, !s.isEmpty else { return fallback }
                return s
            case .unsupported: return fallback
            case .noAnswer, .broken: return nil
            }
        }
    }

    // MARK: MobileDevice-Symbole

    /// Signaturen wie im live geprüften Research/remote-battery-probes/amd_probe.swift.
    /// AMDeviceIsPaired und AMDeviceValidatePairing werden bewusst nicht geladen: auf
    /// macOS 26.7 ist IsPaired nur `ValidatePairing() == 0`, und ValidatePairing ist
    /// StartSession + StopSession (Disassembly) – das erledigt StartSession allein, mit
    /// auswertbarem Fehlercode und ohne zusätzliche Handshakes.
    struct API {
        typealias NotifyCallback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias SubscribeFn = @convention(c) (NotifyCallback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                                UnsafeMutablePointer<UnsafeMutableRawPointer?>, CFDictionary?) -> Int32
        typealias UnsubscribeFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias DeviceCallFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias RetainFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias CopyValueFn = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
        typealias CopyIDFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
        typealias StartServiceFn = @convention(c) (UnsafeMutableRawPointer, CFString, CFDictionary?,
                                                   UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        // AMDServiceConnectionSendMessage(conn, CFPropertyListRef, CFPropertyListFormat)
        typealias SendFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, CFIndex) -> Int32
        // AMDServiceConnectionReceiveMessage(conn, CFPropertyListRef *out, CFPropertyListFormat *fmt) – 3 Argumente
        typealias ReceiveFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                                              UnsafeMutablePointer<CFIndex>?) -> Int32
        typealias InvalidateFn = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias TypeIDFn = @convention(c) () -> CFTypeID

        // Pflicht (sonst isAvailable = false)
        let subscribe: SubscribeFn
        let connect: DeviceCallFn
        let disconnect: DeviceCallFn
        let startSession: DeviceCallFn
        let stopSession: DeviceCallFn
        let interfaceType: DeviceCallFn
        let copyValue: CopyValueFn
        let copyID: CopyIDFn
        let retain: RetainFn
        let release: ReleaseFn
        // Optional (fehlt eines, gibt es eben keine Uhr bzw. kein Abmelden)
        let unsubscribe: UnsubscribeFn?
        let startService: StartServiceFn?
        let send: SendFn?
        let receive: ReceiveFn?
        let invalidate: InvalidateFn?
        let getSocket: DeviceCallFn?
        let serviceTypeID: TypeIDFn?

        var hasServiceIO: Bool { startService != nil && send != nil && receive != nil && invalidate != nil }

        static let shared: API? = load()

        private static func load() -> API? {
            let paths = [
                "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
                "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            ]
            var handle: UnsafeMutableRawPointer?
            for path in paths where handle == nil { handle = dlopen(path, RTLD_NOW) }
            guard let handle else {
                LockdownProvider.log("MobileDevice.framework nicht ladbar")
                return nil
            }
            func sym<T>(_ name: String, _: T.Type) -> T? {
                guard let p = dlsym(handle, name) else { return nil }
                return unsafeBitCast(p, to: T.self)
            }
            guard let subscribe = sym("AMDeviceNotificationSubscribeWithOptions", SubscribeFn.self),
                  let connect = sym("AMDeviceConnect", DeviceCallFn.self),
                  let disconnect = sym("AMDeviceDisconnect", DeviceCallFn.self),
                  let startSession = sym("AMDeviceStartSession", DeviceCallFn.self),
                  let stopSession = sym("AMDeviceStopSession", DeviceCallFn.self),
                  let interfaceType = sym("AMDeviceGetInterfaceType", DeviceCallFn.self),
                  let copyValue = sym("AMDeviceCopyValue", CopyValueFn.self),
                  let copyID = sym("AMDeviceCopyDeviceIdentifier", CopyIDFn.self),
                  let retain = sym("AMDeviceRetain", RetainFn.self),
                  let release = sym("AMDeviceRelease", ReleaseFn.self)
            else {
                LockdownProvider.log("MobileDevice: Symbole fehlen")
                return nil
            }
            return API(subscribe: subscribe, connect: connect, disconnect: disconnect,
                       startSession: startSession, stopSession: stopSession,
                       interfaceType: interfaceType, copyValue: copyValue, copyID: copyID,
                       retain: retain, release: release,
                       unsubscribe: sym("AMDeviceNotificationUnsubscribe", UnsubscribeFn.self),
                       startService: sym("AMDeviceSecureStartService", StartServiceFn.self),
                       send: sym("AMDServiceConnectionSendMessage", SendFn.self),
                       receive: sym("AMDServiceConnectionReceiveMessage", ReceiveFn.self),
                       invalidate: sym("AMDServiceConnectionInvalidate", InvalidateFn.self),
                       getSocket: sym("AMDServiceConnectionGetSocket", DeviceCallFn.self),
                       serviceTypeID: sym("AMDServiceConnectionGetTypeID", TypeIDFn.self))
        }
    }

    // MARK: Arbeitsteil

    final class Engine {
        let api: API
        let callbackBox = CallbackBox()
        weak var provider: LockdownProvider?

        private let stateQueue = DispatchQueue(label: "island.lockdown.state", qos: .utility)
        private let workQueue = DispatchQueue(label: "island.lockdown.work", qos: .utility, attributes: .concurrent)

        // Zustand – nur auf stateQueue
        private var running = false
        private var epoch = 0
        private var generation = 0
        private var busyJobs: [String: Int] = [:]                 // UDID → offene Aufträge (auch hängende)
        private var devices: [String: [Int32: DeviceRef]] = [:]   // UDID → Schnittstelle → Gerät (je +1)
        private var inFlight: [String: (since: TimeInterval, generation: Int)] = [:]   // since = uptime()
        private var lastRead: [String: Date] = [:]
        private var lastWatchCheck: [String: Date] = [:]
        private var lastStatus: [String: StatusMark] = [:]
        private var names: [String: String] = [:]                 // UDID → letzter Gerätename
        private var watches: [String: WatchInfo] = [:]            // Uhr-UDID → Name/Modell

        init(api: API) {
            self.api = api
            callbackBox.engine = self
            // Der Kontext des C-Callbacks darf nie ins Leere zeigen – auch nicht, wenn nach
            // der Abmeldung noch eine Meldung eintrifft. Die winzige Box wird darum bewusst
            // nie freigegeben.
            _ = Unmanaged.passRetained(callbackBox)
        }

        func setRunning(_ on: Bool) {
            stateQueue.async { [self] in
                guard running != on else { return }
                running = on
                epoch += 1                  // Ergebnisse aus der Zeit davor verwerfen
                guard !on else { return }
                for refs in devices.values { for ref in refs.values { api.release(ref) } }
                devices.removeAll()
                lastStatus.removeAll()
                lastRead.removeAll()
                lastWatchCheck.removeAll()
            }
        }

        func pollAll() {
            stateQueue.async { [self] in
                guard running else { return }
                for udid in devices.keys { scheduleRead(udid, trigger: .poll) }
            }
        }

        /// Auf dem Meldungs-Thread: nur festhalten und weitergeben, keine Geräte-Aufrufe.
        func notified(device: DeviceRef, message: UInt32) {
            _ = api.retain(device)          // gilt bis zur Verarbeitung auf stateQueue
            stateQueue.async { [self] in
                if message == 2 {
                    detached(device)
                } else {
                    attached(device, trigger: message == 4 ? .paired : .attach)
                }
            }
        }

        // MARK: Buchhaltung (stateQueue)

        /// `device` kommt mit +1 aus `notified` – wird übernommen oder freigegeben.
        private func attached(_ device: DeviceRef, trigger: Trigger) {
            guard running else { api.release(device); return }
            let iface = api.interfaceType(device)
            guard LockdownProvider.supportedInterfaces.contains(iface), let udid = copyUDID(device) else {
                LockdownProvider.log("Gerät mit Schnittstelle \(iface) ausgelassen")
                api.release(device)
                return
            }
            var refs = devices[udid] ?? [:]
            if let old = refs[iface] {
                if old == device {
                    api.release(device)     // schon gehalten
                } else {
                    api.release(old)
                    refs[iface] = device
                }
            } else {
                refs[iface] = device
            }
            devices[udid] = refs
            LockdownProvider.log("\(udid.prefix(8)): angeschlossen (Schnittstelle \(iface))")
            scheduleRead(udid, trigger: trigger)
        }

        /// `device` kommt mit +1 aus `notified`.
        /// Nur über den Zeiger zuordnen: Ist er nicht (mehr) gespeichert, wurde das Objekt
        /// in `attached` schon durch ein neueres ersetzt (und freigegeben) oder nie gespeichert
        /// (andere Schnittstelle, gestoppt). Ein Rückfall über UDID + Schnittstelle würde bei
        /// WLAN-Wiederverbindungen (Anmelden B, dann spätes Abmelden A) das lebende Gerät B entfernen.
        private func detached(_ device: DeviceRef) {
            defer { api.release(device) }
            var hit: (udid: String, iface: Int32)?
            search: for (udid, refs) in devices {
                for (iface, ref) in refs where ref == device {
                    hit = (udid, iface)
                    break search
                }
            }
            guard let hit, var refs = devices[hit.udid], let ref = refs[hit.iface] else { return }
            api.release(ref)
            refs[hit.iface] = nil
            if refs.isEmpty {
                devices[hit.udid] = nil
                lastStatus[hit.udid] = nil  // beim nächsten Anschliessen wieder melden
            } else {
                devices[hit.udid] = refs
            }
            LockdownProvider.log("\(hit.udid.prefix(8)): getrennt (Schnittstelle \(hit.iface))")
        }

        private func scheduleRead(_ udid: String, trigger: Trigger) {
            guard running, let refs = devices[udid], let device = Self.preferred(refs) else { return }
            let now = Date()                // Entprellen: Wanduhr (nach dem Aufwachen ruhig neu lesen)
            let clock = LockdownProvider.uptime()   // Wachhund: monotone Uhr
            let busy = busyJobs[udid] ?? 0
            if let flight = inFlight[udid] {
                let age = clock - flight.since
                guard age >= LockdownProvider.hungAfter else { return }
                if busy < LockdownProvider.maxJobsPerDevice {
                    LockdownProvider.log("\(udid.prefix(8)): Abfrage hängt seit \(Int(age)) s – neuer Versuch")
                }
            }
            // Ein hängendes Gerät bremst nur sich selbst: neben dem hängenden Auftrag höchstens
            // ein weiterer Versuch. Gilt auch, wenn dieser Versuch fertig ist, der ältere aber
            // noch am Geräte-Mutex von MobileDevice hängt.
            guard busy < LockdownProvider.maxJobsPerDevice else {
                LockdownProvider.log("\(udid.prefix(8)): \(busy) Abfragen hängen – ausgelassen")
                return
            }
            if let last = lastRead[udid] {
                let gap: TimeInterval
                switch trigger {
                case .attach: gap = LockdownProvider.attachDebounce
                case .poll: gap = LockdownProvider.pollDebounce
                case .paired: gap = 0
                }
                if now.timeIntervalSince(last) < gap { return }
            }
            // Obergrenze über verschiedene Geräte; ein Gerät mit offenem Auftrag zählt schon mit.
            guard busy > 0 || busyJobs.count < LockdownProvider.maxBusyDevices else {
                LockdownProvider.log("zu viele Geräte mit offenen Abfragen (\(busyJobs.count)) – \(udid.prefix(8)) übersprungen")
                return
            }
            generation += 1
            let wantWatch = lastWatchCheck[udid].map { now.timeIntervalSince($0) >= LockdownProvider.watchInterval } ?? true
            let job = Job(udid: udid, generation: generation, epoch: epoch,
                          wantWatch: wantWatch, knownWatches: watches)
            inFlight[udid] = (clock, generation)
            busyJobs[udid] = busy + 1
            _ = api.retain(device)          // eigener Verweis für die Dauer der Abfrage
            workQueue.async { [self] in
                let result = read(device, job)
                api.release(device)
                stateQueue.async { self.finish(job, result) }
            }
        }

        private func finish(_ job: Job, _ result: ReadResult) {
            let left = (busyJobs[job.udid] ?? 1) - 1
            busyJobs[job.udid] = left > 0 ? left : nil
            guard inFlight[job.udid]?.generation == job.generation else {
                LockdownProvider.log("\(job.tag): verspätetes Ergebnis verworfen")
                return
            }
            inFlight[job.udid] = nil
            guard running, job.epoch == epoch else { return }

            let now = Date()
            lastRead[job.udid] = now
            if result.watchChecked { lastWatchCheck[job.udid] = now }
            watches.merge(result.watchInfo) { _, new in new }
            if let name = result.name { names[job.udid] = name }

            let statusEvent: StatusMark? = result.status.flatMap { status in
                let mark = StatusMark(status: status, name: result.name ?? names[job.udid] ?? "Gerät \(job.tag)")
                guard lastStatus[job.udid] != mark else { return nil }
                if devices[job.udid] != nil { lastStatus[job.udid] = mark }
                return mark
            }
            let samples = result.samples
            guard statusEvent != nil || !samples.isEmpty else { return }
            DispatchQueue.main.async { [weak target = self.provider] in
                guard let target else { return }
                if let e = statusEvent { target.onStatus?(e.name, e.status) }
                for s in samples { target.onSample?(s) }
            }
        }

        /// Kabel vor WLAN; andere Schnittstellen werden gar nicht erst gespeichert.
        private static func preferred(_ refs: [Int32: DeviceRef]) -> DeviceRef? {
            refs[1] ?? refs[2]
        }

        // MARK: Geräte-Aufrufe (workQueue, blockierend)

        private func read(_ device: DeviceRef, _ job: Job) -> ReadResult {
            let (lockdown, service) = readLockdown(device, job)
            var result = lockdown
            if let service {
                readWatches(service, job: job, into: &result)
                closeService(service)
            }
            return result
        }

        /// Reihenfolge: Connect → StartSession → Werte → (Uhr-Dienst starten) → StopSession →
        /// Disconnect. Ein einziger Sitzungs-Handshake pro Lesen; ob das Gerät nicht vertraut
        /// oder nur gerade nicht erreichbar ist, sagt der Fehlercode von StartSession.
        private func readLockdown(_ device: DeviceRef, _ job: Job) -> (ReadResult, ServiceRef?) {
            var result = ReadResult()
            let deadline = LockdownProvider.uptime() + LockdownProvider.deviceBudget

            let connectRC = api.connect(device)
            guard connectRC == 0 else {
                LockdownProvider.log("\(job.tag): Connect rc=\(LockdownProvider.hex(connectRC))")
                result.status = .sessionFailed
                return (result, nil)
            }
            defer { _ = api.disconnect(device) }

            let sessionRC: Int32 = LockdownProvider.uptime() < deadline ? api.startSession(device) : -1
            if LockdownProvider.notTrustedCodes.contains(UInt32(bitPattern: sessionRC)) {
                // Nicht vertraut: nur Werte, die lockdownd auch ohne Kopplung herausgibt (per Kabel).
                // NIE koppeln – das Vertrauen gibt der Mensch am Gerät.
                let cls = string(device, "DeviceClass"), product = string(device, "ProductType")
                result.name = string(device, "DeviceName")
                if LockdownProvider.kind(deviceClass: cls, productType: product) != nil || (cls == nil && product == nil) {
                    result.status = .notTrusted
                }
                LockdownProvider.log("\(job.tag): nicht vertraut (rc=\(LockdownProvider.hex(sessionRC)))")
                return (result, nil)
            }
            guard sessionRC == 0 else {
                // Vorübergehend (schläft, gesperrt, beschäftigt, weg …) – kein Vertrauens-Hinweis.
                LockdownProvider.log("\(job.tag): StartSession rc=\(LockdownProvider.hex(sessionRC))")
                result.status = .sessionFailed
                return (result, nil)
            }
            defer { _ = api.stopSession(device) }   // läuft vor dem Disconnect oben

            let battery = copy(device, domain: "com.apple.mobile.battery", key: nil) as? [String: Any]
            let observedAt = Date()
            let name = string(device, "DeviceName")
            let product = string(device, "ProductType")
            let cls = string(device, "DeviceClass")
            result.name = name

            guard let kind = LockdownProvider.kind(deviceClass: cls, productType: product) else {
                LockdownProvider.log("\(job.tag): Geräteklasse \(cls ?? "?") – ausgelassen")
                return (result, nil)
            }

            if let percent = LockdownProvider.int(battery?["BatteryCurrentCapacity"]) {
                let charging = LockdownProvider.bool(battery?["BatteryIsCharging"])
                    ?? LockdownProvider.bool(battery?["ExternalConnected"])
                let model = product ?? cls ?? kind.rawValue
                result.samples.append(BatterySample(
                    key: RemoteDeviceKey(kind: kind, model: model, name: name ?? DeviceNames.marketing(model)),
                    parts: [BatteryPart(slot: .main, percent: min(100, max(0, percent)), charging: charging)],
                    precision: .exact, source: .lockdown, observedAt: observedAt))
                result.status = .ok
                LockdownProvider.log("\(job.tag): \(model) \(percent) %\(charging == true ? " (lädt)" : "")")
            } else {
                LockdownProvider.log("\(job.tag): kein Akku-Wert")
                result.status = .sessionFailed
            }

            // Apple Watch: Dienst noch in der offenen Sitzung starten, abgefragt wird danach
            // (Muster von ios-deploy: Dienstverbindung bleibt nach StopSession gültig).
            var service: ServiceRef?
            if kind == .iPhone, job.wantWatch, LockdownProvider.uptime() < deadline,
               api.hasServiceIO, let startService = api.startService {
                var out: UnsafeMutableRawPointer?
                let rc = startService(device, LockdownProvider.companionService as CFString, nil, &out)
                result.watchChecked = true
                if rc == 0, let out {
                    service = out
                } else {
                    LockdownProvider.log("\(job.tag): companion_proxy rc=\(LockdownProvider.hex(rc))")
                }
            }
            return (result, service)
        }

        private func readWatches(_ conn: ServiceRef, job: Job, into result: inout ReadResult) {
            let deadline = LockdownProvider.uptime() + LockdownProvider.watchBudget
            guard let registry = rpc(conn, ["Command": "GetDeviceRegistry"], deadline: deadline) else {
                LockdownProvider.log("\(job.tag): companion_proxy antwortet nicht")
                return
            }
            if let error = registry["Error"] as? String {
                LockdownProvider.log("\(job.tag): Uhr-Register: \(error)")    // „NoPairedWatches“ → keine Uhr
                return
            }
            guard let watchIDs = registry["PairedDevicesArray"] as? [String] else { return }

            watchLoop: for watch in watchIDs.prefix(4) where !watch.isEmpty {
                // Name/Modell nur einmal holen – sie bilden den Schlüssel der Zeile. Ohne
                // gesicherten Namen keine Zeile (sonst entstünden doppelte Einträge).
                var known = job.knownWatches[watch] ?? result.watchInfo[watch]
                if known == nil {
                    let nameReply = registryValue(conn, watch: watch, key: "DeviceName", deadline: deadline)
                    if case .broken = nameReply { break watchLoop }
                    let modelReply = registryValue(conn, watch: watch, key: "ProductType", deadline: deadline)
                    if case .broken = modelReply { break watchLoop }
                    if let name = nameReply.text(fallback: "Apple Watch"),
                       let model = modelReply.text(fallback: "Watch") {
                        known = WatchInfo(name: name, model: model)
                        result.watchInfo[watch] = known
                    }
                }
                guard let info = known else { continue }        // Uhr schläft – nächste Runde

                let capacity = registryValue(conn, watch: watch, key: "BatteryCurrentCapacity", deadline: deadline)
                if case .broken = capacity { break watchLoop }
                guard case .value(let raw) = capacity, let percent = LockdownProvider.int(raw) else { continue }
                let observedAt = Date()
                let chargingReply = registryValue(conn, watch: watch, key: "BatteryIsCharging", deadline: deadline)
                var charging: Bool?
                if case .value(let v) = chargingReply { charging = LockdownProvider.bool(v) }
                result.samples.append(BatterySample(
                    key: RemoteDeviceKey(kind: .watch, model: info.model, name: info.name),
                    parts: [BatteryPart(slot: .main, percent: min(100, max(0, percent)), charging: charging)],
                    precision: .exact, source: .companionProxy, observedAt: observedAt))
                LockdownProvider.log("\(job.tag): Uhr \(info.model) \(percent) %")
                if case .broken = chargingReply { break watchLoop }
            }
        }

        private func registryValue(_ conn: ServiceRef, watch: String, key: String, deadline: TimeInterval) -> RegistryReply {
            let request: [String: Any] = [
                "Command": "GetValueFromRegistry",
                "GetValueGizmoUDIDKey": watch,
                "GetValueKeyKey": key,
            ]
            guard let reply = rpc(conn, request, deadline: deadline) else { return .broken }
            if let values = reply["RetrievedValueDictionary"] as? [String: Any] {
                if let v = values[key] { return .value(v) }
                return .unsupported
            }
            if let error = reply["Error"] as? String, error == "UnsupportedWatchKey" { return .unsupported }
            return .noAnswer
        }

        /// Eine Anfrage/Antwort über die Dienstverbindung (Binär-Plist).
        /// `deadline` auf der monotonen Uhr (`uptime()`).
        private func rpc(_ conn: ServiceRef, _ message: [String: Any], deadline: TimeInterval) -> [String: Any]? {
            guard let send = api.send, let receive = api.receive else { return nil }
            let remaining = deadline - LockdownProvider.uptime()
            guard remaining > 0.25 else { return nil }
            applyTimeout(conn, seconds: remaining)

            let plist = message as NSDictionary
            let sendRC = withExtendedLifetime(plist) {
                send(conn, UnsafeRawPointer(Unmanaged.passUnretained(plist).toOpaque()), LockdownProvider.binaryPlist)
            }
            guard sendRC == 0 else {
                LockdownProvider.log("Senden rc=\(LockdownProvider.hex(sendRC))")
                return nil
            }
            var out: UnsafeMutableRawPointer?
            var format: CFIndex = 0
            let receiveRC = receive(conn, &out, &format)
            guard receiveRC == 0, let out else {
                LockdownProvider.log("Empfangen rc=\(LockdownProvider.hex(receiveRC))")
                return nil
            }
            // Die Antwort entsteht neu (CreatePropertyListFromBuffer) → +1, wir geben sie frei.
            return Unmanaged<AnyObject>.fromOpaque(out).takeRetainedValue() as? [String: Any]
        }

        /// Socket-Zeitlimit auf das Restbudget, damit ein Empfang nicht ewig wartet.
        private func applyTimeout(_ conn: ServiceRef, seconds: TimeInterval) {
            guard let getSocket = api.getSocket else { return }
            let fd = getSocket(conn)
            guard fd >= 0 else { return }
            let s = max(0.5, seconds)
            var tv = timeval(tv_sec: Int(s), tv_usec: Int32((s - s.rounded(.down)) * 1_000_000))
            let len = socklen_t(MemoryLayout<timeval>.size)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, len)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, len)
        }

        private func closeService(_ conn: ServiceRef) {
            api.invalidate?(conn)
            // AMDeviceSecureStartService übergibt die Verbindung mit +1 (Disassembly auf macOS 26.7:
            // AMDServiceConnectionCreate → *out ohne Release; Invalidate schliesst nur den Socket).
            // Freigeben nur, wenn es sicher ein AMDServiceConnection-Objekt ist – sonst lieber
            // ein kleines Leck als ein Absturz.
            guard let typeID = api.serviceTypeID else { return }
            let object = Unmanaged<AnyObject>.fromOpaque(conn)
            if CFGetTypeID(object.takeUnretainedValue()) == typeID() { object.release() }
        }

        // MARK: Kleine Helfer (workQueue/stateQueue)

        private func copy(_ device: DeviceRef, domain: String?, key: String?) -> AnyObject? {
            api.copyValue(device, domain.map { $0 as CFString }, key.map { $0 as CFString })?.takeRetainedValue()
        }

        private func string(_ device: DeviceRef, _ key: String) -> String? {
            guard let s = copy(device, domain: nil, key: key) as? String, !s.isEmpty else { return nil }
            return s
        }

        private func copyUDID(_ device: DeviceRef) -> String? {
            guard let cf = api.copyID(device)?.takeRetainedValue() else { return nil }
            let id = cf as String
            return id.isEmpty ? nil : id
        }
    }
}

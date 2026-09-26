import Foundation
import CoreBluetooth

// AirPods/Beats-Akku aus dem Bluetooth-Signal „Proximity Pairing“ (Apple Continuity,
// Typ 0x07). Klappt auch, wenn die AirPods gerade am iPhone hängen – solange sie in der
// Nähe sind und aus dem Etui genommen wurden oder das Etui offen ist.
// Rein passiv: Es wird nie verbunden, gekoppelt oder selbst etwas gesendet.

/// Dekodierte Proximity-Pairing-Meldung (Langform: TLV 0x07, Länge 0x19, Präfix 0x01).
///
/// Offsets wie CoreBluetooth die Herstellerdaten liefert (inkl. Firmen-ID `4C 00`),
/// für den Fall, dass 0x07 der erste TLV ist. Davor können andere TLVs stehen, darum
/// wird die Liste ab Index 2 abgelaufen und relativ zum TLV-Wert gelesen (p[k] = d[k + 4]).
///
///     [0–1]   4C 00        Apple
///     [2]     07           Proximity Pairing
///     [3]     19           Länge 25
///     [4]     01           Präfix (00 = Kopplungsmodus, anderes Layout → ignoriert)
///     [5–6]   Produkt-ID, little-endian (27 20 → 0x2027)
///     [7]     Status; 0x20 gesetzt = linker Stöpsel ist primär, sonst „gespiegelt“
///     [8]     Stöpsel-Halbbytes: 0–9 → ×10 %, A–E → 100 %, F → unbekannt
///     [9]     tiefes Halbbyte = Etui (gleiche Codierung), hohes = Lade-Bits
///     [10]    Deckel   [11] Farbe   [12] Verbindung (0 = getrennt, ≥ 4 = mit Host verbunden)
///     [13–28] 16 Byte, normalerweise verschlüsselt. Falls Klartext:
///             [14] primär, [15] sekundär, [16] Etui (Bit 7 = lädt, & 0x7F = %, > 100 = unbekannt),
///             [17–19] 1D 7D 64, [20–22] Ende der Geräteadresse oder 00 00 00
struct ProximityPairing: Equatable {
    let productID: UInt16
    /// Status-Bit 0x20: linker Stöpsel ist primär.
    let primaryLeft: Bool
    let status: UInt8
    /// Byte [12]: 0 getrennt, 4 bereit, 5 Musik, 6 Anruf, 7 klingelt, 9 auflegen.
    let connectionState: UInt8
    let lid: UInt8
    let color: UInt8
    /// Der 16-Byte-Schluss war Klartext und hat die Adressprüfung bestanden.
    let tailPlaintext: Bool
    /// Nur bekannte Werte – unbekannte Teile (0xF, 0xFF) fehlen ganz.
    let parts: [BatteryPart]
    let precision: BatteryPrecision

    var connectedToHost: Bool { connectionState != 0 }
    var kind: DeviceKind { Self.kind(forProductID: productID) }
    /// Schlüssel-Format wie in `DeviceNames`: "0x2027".
    var model: String { String(format: "0x%04X", productID) }

    // MARK: Einstellungen (LIVE VERIFIZIEREN)

    /// Welches Halbbyte in [8] gehört dem PRIMÄREN Stöpsel? OpenPods/LibrePods: das tiefe,
    /// also bei gesetztem 0x20 links = tiefes Halbbyte. LinuxPods sagt das Gegenteil.
    /// Live verifizieren: mit system_profiler (device_batteryLevelLeft/Right) vergleichen,
    /// während das Paar am Mac hängt, und hier umstellen, falls nötig.
    static let primaryPodInLowNibble = true
    /// Lade-Bit des primären Stöpsels im hohen Halbbyte von [9]; sekundär ist das andere
    /// der beiden (0x1/0x2), Etui = 0x4. Live verifizieren, zusammen mit der Halbbyte-Reihenfolge.
    static let primaryChargingBit: UInt8 = 0x1
    /// Den 16-Byte-Schluss als Klartext lesen, falls Prüfmuster UND Adresse passen.
    /// Unverifiziert, ob macOS ihn je entschlüsselt liefert – sonst greift die 10-%-Stufe.
    static let tryPlaintextTail = true

    // MARK: Modell-Tabellen

    /// Beats-Produkt-IDs (Continuity liefert sie byte-vertauscht, hier schon als Produkt-ID).
    static let beatsProductIDs: Set<UInt16> = [
        0x2003, // Powerbeats3
        0x2005, // BeatsX
        0x2006, // Solo3
        0x2009, // Studio3
        0x200B, // Powerbeats Pro
        0x200C, // Solo Pro
        0x200D, // Powerbeats 4
        0x2010, // Beats Flex
        0x2011, // Studio Buds
        0x2012, // Fit Pro
        0x2016, // Studio Buds+
        0x2017, // Studio Pro
    ]
    /// Geräte mit nur einem Akku (Bügel/Nackenband) → ein Teil `.main` aus dem tiefen
    /// Halbbyte. Unverifiziert (Aralim hat keines davon).
    static let singleBatteryProductIDs: Set<UInt16> = [
        0x200A, 0x201F,                  // AirPods Max (Lightning, USB-C)
        0x2003, 0x2005, 0x200D, 0x2010,  // Powerbeats3, BeatsX, Powerbeats 4, Flex
        0x2006, 0x2009, 0x200C, 0x2017,  // Solo3, Studio3, Solo Pro, Studio Pro
    ]

    static func kind(forProductID pid: UInt16) -> DeviceKind {
        beatsProductIDs.contains(pid) ? .beats : .airPods
    }

    private static let longLength = 0x19
    private static let plaintextMagic: [UInt8] = [0x1D, 0x7D, 0x64]

    // MARK: Dekodieren

    /// `manufacturerData` = CBAdvertisementDataManufacturerDataKey (inkl. `4C 00`).
    /// `addressSuffix` = letzte 3 Bytes der öffentlichen Adresse (nur für die Klartext-Prüfung).
    static func parse(_ manufacturerData: Data, addressSuffix: [UInt8]?) -> ProximityPairing? {
        guard let p = payload(in: manufacturerData) else { return nil }
        return decode(p, addressSuffix: addressSuffix)
    }

    /// Nur die Produkt-ID (billig, für die „gehört mir“-Prüfung vor dem eigentlichen Parsen).
    static func productID(in manufacturerData: Data) -> UInt16? {
        guard let p = payload(in: manufacturerData), p.count > 2 else { return nil }
        return UInt16(p[1]) | UInt16(p[2]) << 8
    }

    /// Apple-TLVs ab Index 2. Ein abgeschnittener Eintrag beendet die Liste.
    static func tlvs(in manufacturerData: Data) -> [(type: UInt8, value: [UInt8])] {
        let d = [UInt8](manufacturerData)
        guard d.count >= 4, d[0] == 0x4C, d[1] == 0x00 else { return [] }
        var out: [(type: UInt8, value: [UInt8])] = []
        var i = 2
        while i + 2 <= d.count {
            let type = d[i], len = Int(d[i + 1])
            let start = i + 2, end = start + len
            guard end <= d.count else { break }
            out.append((type, Array(d[start..<end])))
            i = end
        }
        return out
    }

    /// Wert des Proximity-Pairing-TLV in Langform, sonst nil.
    static func payload(in manufacturerData: Data) -> [UInt8]? {
        for t in tlvs(in: manufacturerData)
        where t.type == 0x07 && t.value.count == longLength && t.value.first == 0x01 {
            return t.value
        }
        return nil
    }

    private static func decode(_ p: [UInt8], addressSuffix: [UInt8]?) -> ProximityPairing? {
        guard p.count == longLength else { return nil }
        let pid = UInt16(p[1]) | UInt16(p[2]) << 8
        let status = p[3]
        let primaryLeft = status & 0x20 != 0
        let single = singleBatteryProductIDs.contains(pid)
        let tail = Array(p[9..<longLength])                 // d[13…28]
        let plaintext = tryPlaintextTail && isPlaintext(tail, addressSuffix: addressSuffix)

        var parts: [BatteryPart] = []
        var precision = BatteryPrecision.step10
        if plaintext {
            parts = exactParts(tail, primaryLeft: primaryLeft, single: single)
            if !parts.isEmpty { precision = .exact }
        }
        if parts.isEmpty {
            parts = nibbleParts(pods: p[4], caseByte: p[5], primaryLeft: primaryLeft, single: single)
        }
        return ProximityPairing(productID: pid, primaryLeft: primaryLeft, status: status,
                                connectionState: p[8], lid: p[6], color: p[7],
                                tailPlaintext: plaintext, parts: parts, precision: precision)
    }

    /// 0–9 → ×10 %, A–E → 100 %, F → unbekannt.
    static func nibblePercent(_ n: UInt8) -> Int? {
        switch n & 0x0F {
        case 0...9: return Int(n & 0x0F) * 10
        case 0xA...0xE: return 100
        default: return nil
        }
    }

    private static func nibbleParts(pods: UInt8, caseByte: UInt8, primaryLeft: Bool, single: Bool) -> [BatteryPart] {
        let low = pods & 0x0F, high = pods >> 4
        let flags = caseByte >> 4
        if single {
            // Ein Akku: tiefes Halbbyte, lädt = eines der beiden Stöpsel-Bits (unverifiziert).
            guard let pct = nibblePercent(low) else { return [] }
            return [BatteryPart(slot: .main, percent: pct, charging: flags & 0x3 != 0)]
        }
        let (primaryNibble, secondaryNibble) = primaryPodInLowNibble ? (low, high) : (high, low)
        let secondaryBit: UInt8 = primaryChargingBit == 0x1 ? 0x2 : 0x1
        let primaryCharging = flags & primaryChargingBit != 0
        let secondaryCharging = flags & secondaryBit != 0

        let left = primaryLeft ? (primaryNibble, primaryCharging) : (secondaryNibble, secondaryCharging)
        let right = primaryLeft ? (secondaryNibble, secondaryCharging) : (primaryNibble, primaryCharging)

        var out: [BatteryPart] = []
        if let pct = nibblePercent(left.0) { out.append(BatteryPart(slot: .left, percent: pct, charging: left.1)) }
        if let pct = nibblePercent(right.0) { out.append(BatteryPart(slot: .right, percent: pct, charging: right.1)) }
        if let pct = nibblePercent(caseByte & 0x0F) {
            out.append(BatteryPart(slot: .chargingCase, percent: pct, charging: flags & 0x4 != 0))
        }
        return out
    }

    /// Klartext nur, wenn die festen Bytes 1D 7D 64 UND das Adress-Ende (oder 00 00 00) passen.
    private static func isPlaintext(_ tail: [UInt8], addressSuffix: [UInt8]?) -> Bool {
        guard tail.count >= 10, Array(tail[4...6]) == plaintextMagic else { return false }
        let found = Array(tail[7...9])
        if found == [0, 0, 0] { return true }
        guard let s = addressSuffix, s.count == 3 else { return false }
        // Byte-Reihenfolge unklar (auf der Funkstrecke ist die Adresse little-endian) →
        // beide zulassen; die festen Bytes müssen ohnehin stimmen. Live verifizieren.
        return found == s || found == Array(s.reversed())
    }

    private static func exactParts(_ tail: [UInt8], primaryLeft: Bool, single: Bool) -> [BatteryPart] {
        guard tail.count >= 4 else { return [] }
        func exact(_ b: UInt8) -> (percent: Int, charging: Bool)? {
            let pct = Int(b & 0x7F)
            guard b != 0xFF, pct <= 100 else { return nil }
            return (pct, b & 0x80 != 0)
        }
        let primary = tail[1], secondary = tail[2], caseByte = tail[3]
        if single {
            guard let v = exact(primary) else { return [] }
            return [BatteryPart(slot: .main, percent: v.percent, charging: v.charging)]
        }
        let (lb, rb) = primaryLeft ? (primary, secondary) : (secondary, primary)
        var out: [BatteryPart] = []
        if let v = exact(lb) { out.append(BatteryPart(slot: .left, percent: v.percent, charging: v.charging)) }
        if let v = exact(rb) { out.append(BatteryPart(slot: .right, percent: v.percent, charging: v.charging)) }
        if let v = exact(caseByte) {
            out.append(BatteryPart(slot: .chargingCase, percent: v.percent, charging: v.charging))
        }
        return out
    }
}

// MARK: - Scanner

/// Passiver BLE-Scan nach Proximity-Pairing-Meldungen der EIGENEN AirPods/Beats.
///
/// „Eigen“ heisst: Produkt-ID steht in `owned` (gekoppelt mit diesem Mac, aus system_profiler),
/// ein eventuell mitgelieferter Name stimmt überein und das Signal ist stark genug (≥ −75 dBm).
/// Alles andere wird verworfen, bevor irgendetwas geloggt wird (Flipper/ESP32 fälschen 0x07);
/// im Debug erscheint davon höchstens eine Anzahl ohne Namen.
///
/// Threading: Der CBCentralManager läuft auf einer eigenen seriellen Queue; `owned`,
/// `debugRaw` und `onSample` gehören dem Main-Thread, Proben kommen immer auf Main an.
/// `connect` wird NIE aufgerufen.
final class ProximityPairingScanner: NSObject, CBCentralManagerDelegate {
    /// Mindest-Signalstärke gegen fremde AirPods gleichen Modells (127 = „kein Wert“).
    static let minimumRSSI = -75
    /// Unveränderte Werte höchstens so oft melden (AllowDuplicates liefert mehrere pro Sekunde).
    static let repeatInterval: TimeInterval = 15
    /// Pro Gerät höchstens eine Probe in dieser Zeit – auch wenn sich die Meldungen abwechseln.
    static let minimumInterval: TimeInterval = 2
    static let defaultWindow: Double = 6
    /// Debug: höchstens eine Rohdaten-Zeile pro 0,25 s, verworfene Fremde alle 30 s als Anzahl.
    private static let debugLineInterval: TimeInterval = 0.25
    private static let debugRejectInterval: TimeInterval = 30

    /// Gekoppelte Kopfhörer („gehört mir“). Auf Main setzen; der Scanner arbeitet mit einer Kopie.
    var owned: [PairedAudioDevice] = [] {
        didSet {
            let copy = owned
            queue.async { [weak self] in self?.ownedQ = copy }
        }
    }
    /// Immer auf Main.
    var onSample: ((BatterySample) -> Void)?
    /// Bluetooth-Zustand/Freigabe hat sich geändert (auf Main) – z. B. Antwort auf den Systemdialog.
    var onStateChange: (() -> Void)?
    /// ISLAND_DEBUG=1: Rohdaten (Hex) der EIGENEN Geräte nach stderr (gedrosselt).
    var debugRaw = false {
        didSet {
            let value = debugRaw
            queue.async { [weak self] in self?.debugQ = value }
        }
    }

    /// Fragt nicht nach – liest nur den aktuellen TCC-Stand.
    static var authorization: CBManagerAuthorization { CBManager.authorization }

    /// Nur für Debug-Code: prüft den Decoder mit Beispiel-Bytes.
    static func selfTest() -> Bool { ProximityPairing.selfTest() }

    private let queue = DispatchQueue(label: "island.ble.proximity", qos: .utility)

    /// Letzter gemeldeter Stand pro Gerät (fehlende Teile aus früheren Meldungen ergänzt)
    /// und wann welche Genauigkeit zuletzt ankam.
    private struct EmitState {
        var parts: [BatteryPart] = []
        var precision: BatteryPrecision = .bucket4
        var at = Date.distantPast
        var seen: [BatteryPrecision: Date] = [:]
    }

    // Ab hier nur auf `queue` anfassen.
    private var central: CBCentralManager?
    private var ownedQ: [PairedAudioDevice] = []
    private var debugQ = false
    /// Bei „Bluetooth bereit“ von selbst ein Fenster starten? Aus nach `stop()`, damit
    /// Bluetooth aus/an, ein Neustart von bluetoothd oder das Aufwachen nicht mehr scannen.
    private var autoScan = false
    private var scanning = false
    private var scanDeadline: DispatchTime?
    private var stopWork: DispatchWorkItem?
    private var emitState: [RemoteDeviceKey: EmitState] = [:]
    private var debugLastLine = Date.distantPast
    private var debugSkipped = 0
    private var debugRejected = 0
    private var debugRejectedAt = Date.distantPast

    /// Legt den CBCentralManager an – das löst beim allerersten Mal die Bluetooth-Abfrage
    /// von macOS aus. Nichts tun bei „abgelehnt/eingeschränkt“. Besteht der Manager schon
    /// (nach `stop()`), wird nur der Auto-Start wieder eingeschaltet – ohne neue Abfrage.
    func enable() {
        let auth = CBManager.authorization
        guard auth != .denied, auth != .restricted else { return }
        // Ohne diesen Info.plist-Schlüssel beendet TCC den Prozess beim ersten Zugriff.
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            if debugRaw { Self.log("NSBluetoothAlwaysUsageDescription fehlt in Info.plist – Bluetooth bleibt aus") }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let wasOn = self.autoScan
            self.autoScan = true
            if let c = self.central {
                // Wieder eingeschaltet und Bluetooth bereit → gleich ein Fenster wie beim ersten Mal.
                if !wasOn, c.state == .poweredOn { self.startWindow(Self.defaultWindow) }
                return
            }
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    /// Scan-Fenster (alle Dienste, Duplikate erlaubt), danach wieder aus.
    /// Ein laufendes längeres Fenster bleibt. Ist Bluetooth noch nicht bereit, startet das
    /// Fenster, sobald es bereit ist (schaltet den Auto-Start ein – nur aufrufen, wenn die
    /// Funktion in den Einstellungen an ist).
    func scanWindow(seconds: Double = 6) {
        let secs = seconds.isFinite ? min(max(seconds, 1), 120) : Self.defaultWindow
        queue.async { [weak self] in
            guard let self else { return }
            self.autoScan = true
            self.startWindow(secs)
        }
    }

    /// Beendet das Fenster und den Auto-Start (Funktion aus, Ruhezustand). Der Manager
    /// bleibt bestehen, damit `enable()`/`scanWindow()` ohne neue Abfrage weiterlaufen.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.autoScan = false
            self.endWindow()
        }
    }

    deinit {
        // Niemand sonst hält den Scanner mehr, der Zugriff hier ist also exklusiv. Nichts mehr
        // an uns melden; stopScan nur bei „bereit“ (sonst meldet CoreBluetooth „API MISUSE“) –
        // mit dem Manager endet der Scan ohnehin.
        stopWork?.cancel()
        central?.delegate = nil
        if scanning, let c = central, c.state == .poweredOn { c.stopScan() }
    }

    // MARK: Intern (auf queue)

    private func startWindow(_ seconds: Double) {
        guard let c = central, c.state == .poweredOn else { return }
        let deadline = DispatchTime.now() + seconds
        if scanning, let current = scanDeadline, current >= deadline { return }
        if !scanning {
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
        }
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endWindow() }
        stopWork = work
        scanDeadline = deadline
        queue.asyncAfter(deadline: deadline, execute: work)
    }

    private func endWindow() {
        stopWork?.cancel()
        stopWork = nil
        scanDeadline = nil
        if scanning, let c = central, c.state == .poweredOn { c.stopScan() }
        scanning = false
    }

    // MARK: CBCentralManagerDelegate (auf queue)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if central.state == .poweredOn {
            if autoScan { startWindow(Self.defaultWindow) }
        } else {
            // Aus, gesperrt oder abgelehnt: ein laufender Scan endet von selbst.
            stopWork?.cancel()
            stopWork = nil
            scanDeadline = nil
            scanning = false
        }
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 4 else { return }
        let rssi = RSSI.intValue
        let name = peripheral.name

        guard let pid = ProximityPairing.productID(in: data) else {
            if debugQ { debugShortVariant(data, name: name, rssi: rssi) }
            return
        }
        let candidates = ownedQ.filter { $0.productID == pid }
        guard !candidates.isEmpty else { return }            // fremdes Modell → nicht einmal loggen
        let now = Date()
        // Fremder Name (anderes Paar gleichen Modells, Fälschung) → weder Name noch Rohdaten
        // loggen, im Debug nur eine gedrosselte Anzahl.
        guard let device = Self.match(candidates, name: name) else {
            if debugQ { countRejected(now) }
            return
        }
        let rssiOK = rssi != 127 && rssi >= Self.minimumRSSI
        let parsed = ProximityPairing.parse(data, addressSuffix: device.addressSuffix)

        if debugQ {
            let verdict = !rssiOK ? "rssi" : (parsed == nil ? "parse?" : "ok")
            debugAdvert(data, pid: pid, name: name, rssi: rssi, verdict: verdict, parsed: parsed, now: now)
        }
        guard rssiOK, let pp = parsed, !pp.parts.isEmpty else { return }

        let key = RemoteDeviceKey(kind: pp.kind, model: pp.model, name: device.name)
        guard shouldEmit(pp, key: key, now: now) else { return }

        let sample = BatterySample(key: key, parts: pp.parts, precision: pp.precision,
                                   source: .proximity, observedAt: now)
        DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
    }

    /// Drossel: AllowDuplicates liefert mehrere Meldungen pro Sekunde, und die können sich
    /// abwechseln (Etui mal bekannt, mal F; Meldungen beider Stöpsel mit anderen Lade-Bits;
    /// Klartext neben 10-%-Stufe). Jede Probe baut auf Main die Geräteliste neu auf.
    private func shouldEmit(_ pp: ProximityPairing, key: RemoteDeviceKey, now: Date) -> Bool {
        var st = emitState[key] ?? EmitState()
        st.seen[pp.precision] = now
        defer { emitState[key] = st }

        // Eben kam eine genauere Meldung → die gröbere nicht dazwischen (sonst 83 → 80 → 83 %).
        if st.seen.contains(where: { $0.key > pp.precision && now.timeIntervalSince($0.value) < Self.repeatInterval }) {
            return false
        }
        let since = now.timeIntervalSince(st.at)
        // Pro Gerät höchstens eine Probe alle paar Sekunden, egal was drinsteht.
        guard since >= Self.minimumInterval else { return false }
        // Ein fehlender Teil (z. B. Etui = F) ist keine Änderung, nur neue oder andere Werte.
        let known = since < BatterySource.proximity.ttl ? st.parts : []
        let changed = pp.precision != st.precision || pp.parts.contains { !known.contains($0) }
        guard changed || since >= Self.repeatInterval else { return false }

        let slots = Set(pp.parts.map(\.slot))
        st.parts = pp.parts + known.filter { !slots.contains($0.slot) }
        st.precision = pp.precision
        st.at = now
        return true
    }

    /// Mehrere gekoppelte Paare mit gleicher Produkt-ID → nur mit passendem Namen.
    /// Ein mitgelieferter Name muss immer passen.
    private static func match(_ candidates: [PairedAudioDevice], name: String?) -> PairedAudioDevice? {
        if let name {
            let n = name.precomposedStringWithCanonicalMapping
            return candidates.first { $0.name.precomposedStringWithCanonicalMapping == n }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    // MARK: Debug (nur ISLAND_DEBUG=1, nur eigene Geräte, auf queue)

    /// Nur Meldungen, die einem eigenen Gerät zugeordnet sind (Name passt oder einziges Paar
    /// dieses Modells). Namenlose Fälschungen mit eigener Produkt-ID kommen hier auch durch –
    /// darum gedrosselt.
    private func debugAdvert(_ data: Data, pid: UInt16, name: String?, rssi: Int,
                             verdict: String, parsed: ProximityPairing?, now: Date) {
        guard debugAllowed(now) else { return }
        var line = String(format: "0x%04X rssi %d", pid, rssi) + " name „\(name ?? "nil")“ \(verdict)"
        if let pp = parsed {
            let parts = pp.parts.map { "\($0.label.isEmpty ? "M" : $0.label)\($0.percent)\($0.charging == true ? "+" : "")" }
            line += " \(pp.precision) \(parts.joined(separator: " "))"
            line += String(format: " st %02x conn %02x", pp.status, pp.connectionState)
            line += pp.primaryLeft ? " primL" : " primR"
            if pp.tailPlaintext { line += " klartext" }
        }
        debugLine(line + " | " + Self.hex(data))
    }

    /// Kurzform (0x07 mit anderer Länge/Präfix, z. B. `07 11 06` bei geschlossenem Etui):
    /// nur aufzeichnen, nicht auswerten – und nur, wenn der Name einem eigenen Gerät gehört.
    private func debugShortVariant(_ data: Data, name: String?, rssi: Int) {
        guard let name else { return }
        let n = name.precomposedStringWithCanonicalMapping
        guard ownedQ.contains(where: { $0.name.precomposedStringWithCanonicalMapping == n }),
              ProximityPairing.tlvs(in: data).contains(where: { $0.type == 0x07 }),
              debugAllowed(Date()) else { return }
        debugLine("kurz rssi \(rssi) name „\(name)“ | " + Self.hex(data))
    }

    /// Eigene Produkt-ID, aber fremder Name: nur zählen, alle 30 s eine Zeile ohne Namen.
    private func countRejected(_ now: Date) {
        debugRejected += 1
        guard now.timeIntervalSince(debugRejectedAt) >= Self.debugRejectInterval else { return }
        Self.log("\(debugRejected) Meldung(en) eigener Modelle mit fremdem Namen verworfen")
        debugRejected = 0
        debugRejectedAt = now
    }

    /// Höchstens eine Rohdaten-Zeile pro `debugLineInterval`; der Rest wird nur gezählt.
    private func debugAllowed(_ now: Date) -> Bool {
        guard now.timeIntervalSince(debugLastLine) >= Self.debugLineInterval else {
            debugSkipped += 1
            return false
        }
        debugLastLine = now
        return true
    }

    private func debugLine(_ s: String) {
        let skipped = debugSkipped
        debugSkipped = 0
        Self.log(skipped > 0 ? s + " (+\(skipped) übersprungen)" : s)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data(("‹ble› " + s + "\n").utf8))
    }
}

// MARK: - Selbsttest (nur aus Debug-Code aufrufen)

extension ProximityPairing {
    /// Prüft den Decoder mit von Hand gebauten Meldungen nach dem dokumentierten Layout.
    /// Erwartungen richten sich nach den Einstellungen oben (Halbbyte-/Lade-Bit-Reihenfolge).
    static func selfTest() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) { if !ok { failures.append(label) } }

        /// 0x07-TLV (Langform) mit 16-Byte-Schluss.
        func frame(pid: UInt16, status: UInt8, pods: UInt8, caseByte: UInt8,
                   connection: UInt8, tail: [UInt8]) -> [UInt8] {
            [0x07, 0x19, 0x01, UInt8(pid & 0xFF), UInt8(pid >> 8), status, pods, caseByte,
             0x31, 0x00, connection] + tail
        }
        func part(_ slot: BatteryPart.Slot, _ pct: Int, _ charging: Bool) -> BatteryPart {
            BatteryPart(slot: slot, percent: pct, charging: charging)
        }
        let apple: [UInt8] = [0x4C, 0x00]
        let noise: [UInt8] = [0xA5, 0x3C, 0x91, 0x07, 0xE2, 0x4B, 0x18, 0xC6,
                              0x5D, 0x72, 0x0F, 0xB3, 0x69, 0x2E, 0xD4, 0x80]
        let low = primaryPodInLowNibble
        let secondaryBit: UInt8 = primaryChargingBit == 0x1 ? 0x2 : 0x1

        // 1) AirPods Pro 3, links primär, L/R 80/90, Etui 70; Lade-Bits 0x5 (primär + Etui).
        let d1 = Data(apple + frame(pid: 0x2027, status: 0x2B, pods: 0x98, caseByte: 0x57,
                                    connection: 0x05, tail: noise))
        if let pp = parse(d1, addressSuffix: nil) {
            let expected = [part(.left, low ? 80 : 90, 0x5 & primaryChargingBit != 0),
                            part(.right, low ? 90 : 80, 0x5 & secondaryBit != 0),
                            part(.chargingCase, 70, true)]
            check(pp.productID == 0x2027 && pp.model == "0x2027" && pp.kind == .airPods, "1 pid")
            check(pp.primaryLeft && pp.connectedToHost && !pp.tailPlaintext, "1 status")
            check(pp.precision == .step10 && pp.parts == expected, "1 parts")
        } else { check(false, "1 parse") }
        check(productID(in: d1) == 0x2027, "1 peek")

        // 2) AirPods Pro 2, rechts primär, 0x07 NICHT als erster TLV (Nearby Info davor),
        //    ein Stöpsel unbekannt (F), Etui unbekannt (F), Lade-Bit 0x2.
        let nearby: [UInt8] = [0x10, 0x05, 0x01, 0x18, 0x44, 0x9A, 0x2B]
        let d2 = Data(apple + nearby + frame(pid: 0x2014, status: 0x03, pods: 0xF6, caseByte: 0x2F,
                                             connection: 0x00, tail: noise))
        if let pp = parse(d2, addressSuffix: nil) {
            // primär (rechts) sitzt im tiefen Halbbyte (6) → nur rechts bekannt; umgekehrt nur links.
            let expected = low ? [part(.right, 60, 0x2 & primaryChargingBit != 0)]
                               : [part(.left, 60, 0x2 & secondaryBit != 0)]
            check(pp.productID == 0x2014 && !pp.primaryLeft && !pp.connectedToHost, "2 status")
            check(pp.precision == .step10 && pp.parts == expected, "2 parts")
        } else { check(false, "2 parse") }

        // 3) Klartext-Schluss: 83 % lädt / 79 % / Etui unbekannt, Adress-Ende 8E E1 2F.
        let suffix: [UInt8] = [0x8E, 0xE1, 0x2F]
        let plain: [UInt8] = [0x10, 0xD3, 0x4F, 0xFF, 0x1D, 0x7D, 0x64] + suffix
            + [0x00, 0x00, 0x12, 0x34, 0x56, 0x78]
        let d3 = Data(apple + frame(pid: 0x2014, status: 0x21, pods: 0x88, caseByte: 0x06,
                                    connection: 0x00, tail: plain))
        let coarse3 = [part(.left, 80, false), part(.right, 80, false), part(.chargingCase, 60, false)]
        if let pp = parse(d3, addressSuffix: suffix) {
            if tryPlaintextTail {
                check(pp.tailPlaintext && pp.precision == .exact
                      && pp.parts == [part(.left, 83, true), part(.right, 79, false)], "3 exact")
            } else {
                check(pp.precision == .step10 && pp.parts == coarse3, "3 coarse (aus)")
            }
        } else { check(false, "3 parse") }
        // Gleiche Bytes, aber fremde/fehlende Adresse → keine Klartext-Annahme, 10-%-Stufe.
        if let pp = parse(d3, addressSuffix: nil) {
            check(!pp.tailPlaintext && pp.precision == .step10 && pp.parts == coarse3, "3 no suffix")
        } else { check(false, "3 parse ohne Adresse") }

        // 4) Ein-Akku-Gerät (AirPods Max USB-C) und Beats-Tabelle.
        let d4 = Data(apple + frame(pid: 0x201F, status: 0x20, pods: 0xF7, caseByte: 0x0F,
                                    connection: 0x04, tail: noise))
        check(parse(d4, addressSuffix: nil)?.parts == [part(.main, 70, false)], "4 single")
        check(kind(forProductID: 0x200B) == .beats && kind(forProductID: 0x2027) == .airPods, "4 kind")

        // 5) Kaputtes und Fremdes wird abgelehnt.
        check(parse(Data(), addressSuffix: nil) == nil, "5 leer")
        check(parse(Data([0x4C, 0x00, 0x07, 0x19, 0x01, 0x27, 0x20]), addressSuffix: nil) == nil, "5 kurz")
        check(parse(Data([0x06, 0x00] + frame(pid: 0x2027, status: 0x20, pods: 0x99, caseByte: 0x09,
                                              connection: 0, tail: noise)), addressSuffix: nil) == nil, "5 firma")
        var pairingMode = frame(pid: 0x2027, status: 0x20, pods: 0x99, caseByte: 0x09, connection: 0, tail: noise)
        pairingMode[2] = 0x00
        check(parse(Data(apple + pairingMode), addressSuffix: nil) == nil, "5 koppelmodus")
        check(parse(Data(apple + [0x07, 0xFF, 0x01]), addressSuffix: nil) == nil, "5 länge")

        if !failures.isEmpty {
            FileHandle.standardError.write(Data(("‹ble› Selbsttest fehlgeschlagen: "
                                                 + failures.joined(separator: ", ") + "\n").utf8))
        }
        return failures.isEmpty
    }
}

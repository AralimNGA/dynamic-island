import Foundation
import Combine

/// Battery levels of connected Bluetooth Apple devices (AirPods, Magic
/// Mouse/Keyboard/Trackpad …) via `system_profiler SPBluetoothDataType`.
/// Caches the last-known level so devices still show after they disconnect
/// (like Apple's Batteries widget).
final class DeviceBatteryService: ObservableObject {
    struct Reading: Equatable, Codable { let label: String; let percent: Int }
    struct Device: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let symbol: String
        let readings: [Reading]
        let connected: Bool
        let lastSeen: Date?
    }

    @Published var devices: [Device] = []
    @Published var loading = false
    /// Alle gekoppelten Apple-Kopfhörer (verbunden oder nicht) – für den AirPods-Scanner.
    @Published var pairedAudio: [PairedAudioDevice] = []

    private struct Cached: Codable { let symbol: String; let readings: [Reading]; let lastSeen: Date }
    private var cache: [String: Cached] = [:]
    private let cacheKey = "deviceBatteryCache"

    init() { loadCache(); rebuild(live: []) }

    func refresh() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let json = Self.runProfiler()
            let live = Self.parse(json)
            let paired = Self.parsePairedAudio(json)
            DispatchQueue.main.async {
                self.rebuild(live: live)
                if let paired, paired != self.pairedAudio { self.pairedAudio = paired }
                self.loading = false
            }
        }
    }

    private func rebuild(live: [(name: String, symbol: String, readings: [Reading])]) {
        let now = Date()
        var liveNames = Set<String>()
        for d in live {
            liveNames.insert(d.name)
            cache[d.name] = Cached(symbol: d.symbol, readings: d.readings, lastSeen: now)
        }
        if !live.isEmpty { saveCache() }

        var result: [Device] = live.map {
            Device(name: $0.name, symbol: $0.symbol, readings: $0.readings, connected: true, lastSeen: now)
        }
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)   // keep cached for 14 days
        for (name, c) in cache where !liveNames.contains(name) && c.lastSeen > cutoff {
            result.append(Device(name: name, symbol: c.symbol, readings: c.readings,
                                 connected: false, lastSeen: c.lastSeen))
        }
        result.sort {
            if $0.connected != $1.connected { return $0.connected }
            return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }
        devices = result
    }

    // MARK: Cache persistence

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: Cached].self, from: data) {
            cache = decoded
        }
    }
    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    // MARK: system_profiler

    private static func runProfiler() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parse(_ json: [String: Any]?) -> [(name: String, symbol: String, readings: [Reading])] {
        guard let arr = json?["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [(String, String, [Reading])] = []
        for section in arr {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, val) in entry {
                    guard let fields = val as? [String: Any] else { continue }
                    var readings: [Reading] = []
                    func add(_ key: String, _ label: String) {
                        if let s = fields[key] as? String, let p = pct(s) {
                            readings.append(Reading(label: label, percent: p))
                        }
                    }
                    add("device_batteryLevelMain", "")
                    add("device_batteryLevelLeft", "L")
                    add("device_batteryLevelRight", "R")
                    add("device_batteryLevelCase", "Case")
                    if !readings.isEmpty { out.append((name, symbol(for: name), readings)) }
                }
            }
        }
        return out
    }

    /// Apple-Kopfhörer aus „verbunden“ und „nicht verbunden“ (Produkt-ID + Adresse).
    /// nil = system_profiler lieferte nichts Brauchbares (alte Liste behalten).
    private static func parsePairedAudio(_ json: [String: Any]?) -> [PairedAudioDevice]? {
        guard let arr = json?["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var out: [PairedAudioDevice] = []
        for section in arr {
            for key in ["device_connected", "device_not_connected"] {
                guard let list = section[key] as? [[String: Any]] else { continue }
                for entry in list {
                    for (name, val) in entry {
                        guard let f = val as? [String: Any],
                              (f["device_vendorID"] as? String)?.lowercased() == "0x004c",
                              (f["device_minorType"] as? String) == "Headphones",
                              let pidStr = f["device_productID"] as? String,
                              let pid = UInt16(pidStr.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16),
                              let addr = f["device_address"] as? String else { continue }
                        out.append(PairedAudioDevice(name: name, productID: pid, address: addr))
                    }
                }
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func pct(_ s: String) -> Int? {
        Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") { return "airpodspro" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("keyboard") { return "keyboard.fill" }
        if n.contains("trackpad") { return "trackpad.fill" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("pencil") { return "applepencil" }
        if n.contains("beats") || n.contains("headphone") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

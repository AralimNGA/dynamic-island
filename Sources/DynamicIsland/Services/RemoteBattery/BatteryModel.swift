import Foundation

// Gemeinsames Datenmodell für Akkustände von Geräten, die NICHT (nur) am Mac
// hängen: iPhone/iPad (Instant Hotspot, Kabel-Kopplung), Apple Watch (über das
// iPhone), AirPods am iPhone (Bluetooth-Signale in der Nähe).

enum DeviceKind: String, Codable {
    case iPhone, iPad, watch, airPods, beats, accessory
}

/// Wie genau ein Wert ist – bestimmt, welche Quelle gewinnt und wie er angezeigt wird.
enum BatteryPrecision: Int, Codable, Comparable {
    case bucket4 = 0     // Instant Hotspot: 20 / 50 / 75 / 100
    case step10 = 1      // AirPods-Signal: 10-%-Schritte
    case exact = 2       // Kabel-Kopplung, Mac-Bluetooth, entschlüsselte AirPods-Werte

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum BatterySource: String, Codable {
    case macBluetooth      // system_profiler (am Mac verbunden)
    case lockdown          // MobileDevice (Kabel/WLAN-Kopplung)
    case companionProxy    // Apple Watch über das iPhone
    case proximity         // AirPods-Bluetooth-Signal
    case hotspot           // Instant Hotspot (Sharing.framework)

    /// So lange gilt ein Wert als frisch.
    var ttl: TimeInterval {
        switch self {
        case .macBluetooth: return 120
        case .lockdown: return 900
        case .companionProxy: return 1200
        case .proximity: return 600
        case .hotspot: return 900
        }
    }
}

struct BatteryPart: Codable, Equatable, Hashable {
    enum Slot: String, Codable { case main, left, right, chargingCase }
    let slot: Slot
    let percent: Int
    let charging: Bool?

    var label: String {
        switch slot {
        case .main: return ""
        case .left: return "L"
        case .right: return "R"
        case .chargingCase: return "Case"
        }
    }
}

/// Name allein ist nicht eindeutig (zwei „iPhone von Aralim“) → Art + Modell + Name.
struct RemoteDeviceKey: Hashable, Codable {
    let kind: DeviceKind
    let model: String       // "iPhone17,1", "0x2027" (AirPods-Produkt-ID) …
    let name: String
}

struct BatterySample: Codable, Equatable {
    let key: RemoteDeviceKey
    let parts: [BatteryPart]
    let precision: BatteryPrecision
    let source: BatterySource
    let observedAt: Date
}

enum DeviceNames {
    /// Marketing-Name für ein Modell-Kürzel. Reihenfolge: feste Tabelle (aus
    /// Xcodes device_traits.db, Stand Xcode 27) → Xcode-Datenbank zur Laufzeit
    /// (für neuere Modelle) → Kürzel selbst.
    static func marketing(_ model: String) -> String {
        if let n = table[model] { return n }
        if let n = cachedXcodeName(model) { return n }
        resolveInBackground(model)          // nie den Main-Thread blockieren
        return model
    }

    /// Wird gerufen, sobald ein Name im Hintergrund aufgelöst wurde (auf Main).
    static var onNameResolved: (() -> Void)?

    private static let table: [String: String] = [
            "iPad13,1": "iPad Air (4th generation)",
            "iPad13,2": "iPad Air (4th generation)",
            "iPad13,4": "iPad Pro (11″) (3rd generation)",
            "iPad13,5": "iPad Pro (11″) (3rd generation)",
            "iPad13,6": "iPad Pro (11″) (3rd generation)",
            "iPad13,7": "iPad Pro (11″) (3rd generation)",
            "iPad13,8": "iPad Pro (12.9″) (5th generation)",
            "iPad13,9": "iPad Pro (12.9″) (5th generation)",
            "iPad13,10": "iPad Pro (12.9″) (5th generation)",
            "iPad13,11": "iPad Pro (12.9″) (5th generation)",
            "iPad13,16": "iPad Air (5th generation)",
            "iPad13,17": "iPad Air (5th generation)",
            "iPad13,18": "iPad (10th generation)",
            "iPad13,19": "iPad (10th generation)",
            "iPad14,1": "iPad mini (6th generation)",
            "iPad14,2": "iPad mini (6th generation)",
            "iPad14,3": "iPad Pro (11″) (4th generation)",
            "iPad14,4": "iPad Pro (11″) (4th generation)",
            "iPad14,5": "iPad Pro (12.9″) (6th generation)",
            "iPad14,6": "iPad Pro (12.9″) (6th generation)",
            "iPad14,8": "iPad Air 11″ (M2)",
            "iPad14,9": "iPad Air 11″ (M2)",
            "iPad14,10": "iPad Air 13″ (M2)",
            "iPad14,11": "iPad Air 13″ (M2)",
            "iPad15,3": "iPad Air 11″ (M3)",
            "iPad15,4": "iPad Air 11″ (M3)",
            "iPad15,5": "iPad Air 13″ (M3)",
            "iPad15,6": "iPad Air 13″ (M3)",
            "iPad15,7": "iPad (A16)",
            "iPad15,8": "iPad (A16)",
            "iPad16,1": "iPad mini (A17 Pro)",
            "iPad16,2": "iPad mini (A17 Pro)",
            "iPad16,3": "iPad Pro 11″ (M4)",
            "iPad16,4": "iPad Pro 11″ (M4)",
            "iPad16,5": "iPad Pro 13″ (M4)",
            "iPad16,6": "iPad Pro 13″ (M4)",
            "iPad16,8": "iPad Air 11″ (M4)",
            "iPad16,9": "iPad Air 11″ (M4)",
            "iPad16,10": "iPad Air 13″ (M4)",
            "iPad16,11": "iPad Air 13″ (M4)",
            "iPad17,1": "iPad Pro 11″ (M5)",
            "iPad17,2": "iPad Pro 11″ (M5)",
            "iPad17,3": "iPad Pro 13″ (M5)",
            "iPad17,4": "iPad Pro 13″ (M5)",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone18,5": "iPhone 17e",
            "iPhone19,2": "iPhone 18 Pro",
            "iPhone19,3": "iPhone 18 Pro Max",
            "iPhone19,4": "iPhone",
            "iPhone19,7": "iPhone 18 Pro Max",
            "0x2014": "AirPods Pro 2", "0x2024": "AirPods Pro 2 (USB-C)", "0x2027": "AirPods Pro 3",
            "0x200E": "AirPods Pro", "0x2013": "AirPods 3", "0x2019": "AirPods 4",
            "0x201B": "AirPods 4 (ANC)", "0x200A": "AirPods Max", "0x201F": "AirPods Max (USB-C)",
    ]

    private static var xcodeCache: [String: String?] = [:]
    private static var pending = Set<String>()
    private static let xcodeLock = NSLock()
    private static let lookupQueue = DispatchQueue(label: "island.devicenames", qos: .utility)

    private static func cachedXcodeName(_ model: String) -> String? {
        xcodeLock.lock(); defer { xcodeLock.unlock() }
        return xcodeCache[model] ?? nil
    }

    private static func resolveInBackground(_ model: String) {
        xcodeLock.lock()
        let skip = xcodeCache[model] != nil || pending.contains(model)
        if !skip { pending.insert(model) }
        xcodeLock.unlock()
        guard !skip else { return }
        lookupQueue.async {
            let name = xcodeLookup(model)
            xcodeLock.lock()
            xcodeCache[model] = .some(name)
            pending.remove(model)
            xcodeLock.unlock()
            if name != nil { DispatchQueue.main.async { onNameResolved?() } }
        }
    }

    /// Fragt Xcodes Gerätedatenbank (falls installiert) ab – nur im Hintergrund.
    private static func xcodeLookup(_ model: String) -> String? {
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad") || model.hasPrefix("Watch"),
              model.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "," }) else { return nil }
        let platform = model.hasPrefix("Watch") ? "WatchOS" : "iPhoneOS"
        let db = "/Applications/Xcode.app/Contents/Developer/Platforms/\(platform).platform/usr/standalone/device_traits.db"
        var result: String?
        if FileManager.default.fileExists(atPath: db) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = ["-readonly", db,
                           "select ProductDescription from Devices where ProductType in ('\(model)','\(model)-A') limit 1;"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !s.isEmpty { result = s.replacingOccurrences(of: "-inch", with: "″") }
            }
        }
        return result
    }

    static func symbol(for kind: DeviceKind, model: String) -> String {
        switch kind {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .watch: return "applewatch"
        case .beats: return "beats.headphones"
        case .accessory: return "dot.radiowaves.left.and.right"
        case .airPods:
            switch model {
            case "0x200A", "0x201F": return "airpodsmax"
            case "0x200E", "0x2014", "0x2024", "0x2027": return "airpodspro"
            default: return "airpods"
            }
        }
    }
}

/// Mit diesem Mac gekoppelte Apple-Kopfhörer (auch wenn gerade nicht verbunden) –
/// aus system_profiler. Dient dem AirPods-Scanner als „gehört mir“-Liste.
struct PairedAudioDevice: Equatable, Hashable {
    let name: String
    let productID: UInt16        // z. B. 0x2027
    let address: String          // z. B. "AA:BB:CC:DD:EE:FF"

    /// Letzte 3 Bytes der Adresse (für die Prüfung des AirPods-Klartexts).
    var addressSuffix: [UInt8]? {
        let bytes = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? Array(bytes.suffix(3)) : nil
    }
}

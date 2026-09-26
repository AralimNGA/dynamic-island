import SwiftUI
import Combine

extension Notification.Name {
    static let openIslandSettings = Notification.Name("openIslandSettings")
}

/// Persisted user configuration, edited via the Settings window.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum AIProvider: String, CaseIterable, Identifiable {
        case anthropic, lmStudio
        var id: String { rawValue }
        var title: String {
            switch self {
            case .anthropic: return "Anthropic API"
            case .lmStudio:  return "LM Studio (lokal, kostenlos)"
            }
        }
    }

    struct Playlist: Identifiable, Codable, Equatable {
        var name: String
        var uri: String
        var id: String { uri }
    }

    static let anthropicModels: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Opus 5.5 (beste Qualität)"),
        ("claude-sonnet-5", "Sonnet 5 (ausgewogen)"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5 (schnell & günstig)"),
    ]

    private let d = UserDefaults.standard

    @Published var aiProvider: AIProvider { didSet { d.set(aiProvider.rawValue, forKey: "aiProvider") } }
    @Published var lmStudioURL: String { didSet { d.set(lmStudioURL, forKey: "lmStudioURL") } }
    @Published var lmStudioModel: String { didSet { d.set(lmStudioModel, forKey: "lmStudioModel") } }
    @Published var anthropicModel: String { didSet { d.set(anthropicModel, forKey: "anthropicModel") } }
    @Published var accentName: String { didSet { d.set(accentName, forKey: "accentName") } }
    @Published var notchFlare: Double { didSet { d.set(notchFlare, forKey: "notchFlare") } }
    @Published var enabledTabs: Set<String> { didSet { d.set(Array(enabledTabs), forKey: "enabledTabs") } }
    @Published var playlists: [Playlist] { didSet { savePlaylists() } }
    @Published var stockSymbols: [String] { didSet { d.set(stockSymbols, forKey: "stockSymbols") } }
    /// Lets the assistant control the Mac (open apps/URLs, volume, etc.) via tools.
    @Published var assistantMacControl: Bool { didSet { d.set(assistantMacControl, forKey: "assistantMacControl") } }

    // Verhalten
    @Published var openOnHover: Bool { didSet { d.set(openOnHover, forKey: "openOnHover") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var hideInScreenshots: Bool { didSet { d.set(hideInScreenshots, forKey: "hideInScreenshots") } }

    /// Now Playing systemweit über MediaRemote (jede App), sonst nur Spotify/Music/Browser.
    @Published var systemNowPlaying: Bool { didSet { d.set(systemNowPlaying, forKey: "systemNowPlaying") } }

    // Akku anderer Geräte
    @Published var remoteBatteryHotspot: Bool { didSet { d.set(remoteBatteryHotspot, forKey: "remoteBatteryHotspot") } }
    @Published var remoteBatteryBLE: Bool { didSet { d.set(remoteBatteryBLE, forKey: "remoteBatteryBLE") } }
    @Published var remoteBatteryLockdown: Bool { didSet { d.set(remoteBatteryLockdown, forKey: "remoteBatteryLockdown") } }

    // Live-Aktivitäten
    @Published var trackBanner: Bool { didSet { d.set(trackBanner, forKey: "trackBanner") } }
    @Published var volumeHUD: Bool { didSet { d.set(volumeHUD, forKey: "volumeHUD") } }
    @Published var replaceSystemHUD: Bool { didSet { d.set(replaceSystemHUD, forKey: "replaceSystemHUD") } }
    @Published var deviceBanner: Bool { didSet { d.set(deviceBanner, forKey: "deviceBanner") } }
    @Published var showPrivacyIndicator: Bool { didSet { d.set(showPrivacyIndicator, forKey: "showPrivacyIndicator") } }
    @Published var unlockAnimation: Bool { didSet { d.set(unlockAnimation, forKey: "unlockAnimation") } }
    @Published var batteryAlerts: Bool { didSet { d.set(batteryAlerts, forKey: "batteryAlerts") } }

    private init() {
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .anthropic
        lmStudioURL = d.string(forKey: "lmStudioURL") ?? "http://localhost:1234/v1/chat/completions"
        lmStudioModel = d.string(forKey: "lmStudioModel") ?? "local-model"
        let storedModel = d.string(forKey: "anthropicModel") ?? ""
        anthropicModel = Self.anthropicModels.contains { $0.id == storedModel } ? storedModel : "claude-opus-5-5"
        accentName = d.string(forKey: "accentName") ?? "pink"
        notchFlare = d.object(forKey: "notchFlare") != nil ? d.double(forKey: "notchFlare") : 11
        if let arr = d.array(forKey: "enabledTabs") as? [String], !arr.isEmpty {
            enabledTabs = Set(arr)
        } else {
            enabledTabs = Set(ExpandedTab.allCases.map { $0.rawValue })
        }
        if let data = d.data(forKey: "playlists"),
           let arr = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = arr
        } else {
            playlists = []
        }
        stockSymbols = (d.array(forKey: "stockSymbols") as? [String]) ?? ["AAPL", "MSFT", "NVDA"]
        assistantMacControl = d.object(forKey: "assistantMacControl") != nil
            ? d.bool(forKey: "assistantMacControl") : true

        let ud = UserDefaults.standard
        let flag = { (key: String, def: Bool) -> Bool in ud.object(forKey: key) != nil ? ud.bool(forKey: key) : def }
        openOnHover = flag("openOnHover", true)
        hoverDelay = ud.object(forKey: "hoverDelay") != nil ? ud.double(forKey: "hoverDelay") : 0.12
        haptics = flag("haptics", true)
        hideInScreenshots = flag("hideInScreenshots", true)
        systemNowPlaying = flag("systemNowPlaying", true)
        remoteBatteryHotspot = flag("remoteBatteryHotspot", true)
        remoteBatteryBLE = flag("remoteBatteryBLE", false)      // erst nach „Bluetooth erlauben“
        remoteBatteryLockdown = flag("remoteBatteryLockdown", true)
        trackBanner = flag("trackBanner", true)
        volumeHUD = flag("volumeHUD", true)
        replaceSystemHUD = flag("replaceSystemHUD", true)
        deviceBanner = flag("deviceBanner", true)
        showPrivacyIndicator = flag("showPrivacyIndicator", true)
        unlockAnimation = flag("unlockAnimation", true)
        batteryAlerts = flag("batteryAlerts", true)

        // Version 2: neuer Übersicht-Tab einmalig einschalten.
        if !d.bool(forKey: "migratedHomeTab") {
            enabledTabs.insert(ExpandedTab.home.rawValue)
            d.set(Array(enabledTabs), forKey: "enabledTabs")
            d.set(true, forKey: "migratedHomeTab")
        }
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { d.set(data, forKey: "playlists") }
    }

    // MARK: Accent

    static let accentOptions: [(name: String, color: Color)] = [
        ("pink", .pink), ("blue", .blue), ("purple", .purple), ("indigo", .indigo),
        ("teal", .teal), ("green", .green), ("orange", .orange), ("red", .red),
    ]

    var accentColor: Color {
        Self.accentOptions.first { $0.name == accentName }?.color ?? .pink
    }

    // MARK: Tabs

    func isEnabled(_ tab: ExpandedTab) -> Bool { enabledTabs.contains(tab.rawValue) }

    func setEnabled(_ tab: ExpandedTab, _ on: Bool) {
        if on { enabledTabs.insert(tab.rawValue) } else { enabledTabs.remove(tab.rawValue) }
        // Never allow an empty tab bar.
        if enabledTabs.isEmpty { enabledTabs = [ExpandedTab.nowPlaying.rawValue] }
    }

    var orderedEnabledTabs: [ExpandedTab] {
        ExpandedTab.allCases.filter { enabledTabs.contains($0.rawValue) }
    }
}

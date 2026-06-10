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
        ("claude-opus-4-8", "Opus 4.8 (beste Qualität)"),
        ("claude-sonnet-4-6", "Sonnet 4.6 (ausgewogen)"),
        ("claude-haiku-4-5", "Haiku 4.5 (schnell & günstig)"),
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

    private init() {
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .anthropic
        lmStudioURL = d.string(forKey: "lmStudioURL") ?? "http://localhost:1234/v1/chat/completions"
        lmStudioModel = d.string(forKey: "lmStudioModel") ?? "local-model"
        anthropicModel = d.string(forKey: "anthropicModel") ?? "claude-opus-4-8"
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

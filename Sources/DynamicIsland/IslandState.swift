import SwiftUI
import Combine

/// Which panel is shown when the island is fully expanded.
enum ExpandedTab: String, CaseIterable, Identifiable {
    case home
    case nowPlaying
    case claude
    case mirror
    case recorder
    case shelf
    case timer
    case todo
    case weather
    case stocks
    case devices
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:       return "Übersicht"
        case .nowPlaying: return "Musik"
        case .claude:     return "Claude"
        case .mirror:     return "Spiegel"
        case .recorder:   return "Aufnahme"
        case .shelf:      return "Ablage"
        case .timer:      return "Timer"
        case .todo:       return "To-Dos"
        case .weather:    return "Wetter"
        case .stocks:     return "Aktien"
        case .devices:    return "Geräte"
        case .calendar:   return "Kalender"
        }
    }

    var icon: String {
        switch self {
        case .home:       return "square.grid.2x2.fill"
        case .nowPlaying: return "music.note"
        case .claude:     return "sparkles"
        case .mirror:     return "camera"
        case .recorder:   return "mic"
        case .shelf:      return "tray.full"
        case .timer:      return "timer"
        case .todo:       return "checklist"
        case .weather:    return "cloud.sun.fill"
        case .stocks:     return "chart.line.uptrend.xyaxis"
        case .devices:    return "battery.100"
        case .calendar:   return "calendar"
        }
    }
}

/// Compact „Live Activity“ links/rechts um die Kamera – wie die kompakte
/// Darstellung auf dem iPhone.
enum IslandActivity: Equatable {
    case idle
    case mediaPeek
    case timerRunning
    case charging(percent: Int, full: Bool)
    case lowBattery(percent: Int)
    case volume(level: Double, muted: Bool, symbol: String)
    case brightness(level: Double)
    case unlocked
    case privacy(camera: Bool, mic: Bool)
    case fileDrop
    case custom(symbol: String, text: String, tint: ColorToken)

    /// HUDs aktualisieren sich live, ohne die Island neu aufploppen zu lassen.
    var isHUD: Bool {
        switch self {
        case .volume, .brightness: return true
        default: return false
        }
    }

    /// Grobe Art – für Animationen (gleiche Art = nur Inhalt ändert sich).
    var kind: String {
        switch self {
        case .idle: return "idle"
        case .mediaPeek: return "media"
        case .timerRunning: return "timer"
        case .charging: return "charging"
        case .lowBattery: return "low"
        case .volume, .brightness: return "hud"
        case .unlocked: return "unlocked"
        case .privacy: return "privacy"
        case .fileDrop: return "drop"
        case .custom: return "custom"
        }
    }
}

/// Mittelgrosse Mitteilung unter der Notch (iPhone: „expanded“ bei Alerts).
enum IslandBanner: Equatable {
    case track
    case device(name: String, symbol: String, readings: [DeviceBatteryService.Reading])
    case message(symbol: String, title: String, subtitle: String, tint: ColorToken)
}

/// A Codable-free color token so IslandActivity stays Equatable cheaply.
enum ColorToken: Equatable {
    case green, blue, orange, red, purple, white, yellow
    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .white: return .white
        case .yellow: return .yellow
        }
    }
}

/// Die vier Grössen der Island (plus „Lippe“ als Hover-Vorschau).
enum IslandPresentation: Equatable {
    case hidden      // nichts gezeichnet – physische Notch bleibt, wie sie ist
    case lip         // Cursor über der Notch: leichtes Aufquellen als Rückmeldung
    case compact     // Live Activity links/rechts der Kamera
    case banner      // Mitteilung unter der Notch
    case expanded    // voll geöffnet mit Tabs
}

/// Central UI / morph state for the island.
final class IslandState: ObservableObject {
    @Published var hovering = false
    @Published var hoverIntent = false        // Cursor ist über der Notch, Öffnen steht bevor
    @Published var pinnedOpen = false         // clicked open, stays until the cursor leaves
    @Published var selectedTab: ExpandedTab = .home
    @Published var transientActivity: IslandActivity = .idle
    @Published var banner: IslandBanner?
    @Published var privacy = PrivacyMonitor.Usage()
    @Published var dragActive = false         // a file is hovering over the island
    @Published var metrics: NotchMetrics
    /// Nach programmatischem Öffnen (Menü, Assistent) kurz nicht gleich zuklappen.
    var graceUntil = Date.distantPast
    /// Hält die Island offen (z. B. offene Bestätigungskarte des Assistenten).
    var holdOpen: () -> Bool = { false }

    private var clearWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?

    init(metrics: NotchMetrics) { self.metrics = metrics }

    var isExpanded: Bool { hovering || pinnedOpen }

    /// Briefly present a live-activity peek, then fall back to idle.
    func flashActivity(_ activity: IslandActivity, duration: TimeInterval = 3.5) {
        clearWork?.cancel()
        if transientActivity.kind == activity.kind && activity.isHUD {
            transientActivity = activity                 // HUD: nur Wert ändern, kein neues Aufploppen
        } else {
            withAnimation(.islandOpen) { transientActivity = activity }
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.islandClose) { self?.transientActivity = .idle }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Mitteilung unter der Notch zeigen (nicht, wenn die Island offen ist).
    func showBanner(_ b: IslandBanner, duration: TimeInterval = 3.0) {
        guard !isExpanded else { return }
        bannerWork?.cancel()
        withAnimation(.islandOpen) { banner = b }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.islandClose) { self?.banner = nil }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Ein bestehendes Banner still aktualisieren (z. B. Akkustand nachgeladen).
    func updateBanner(_ b: IslandBanner) {
        guard banner != nil else { return }
        withAnimation(.islandSnappy) { banner = b }
    }

    func dismissBanner() {
        bannerWork?.cancel()
        withAnimation(.islandClose) { banner = nil }
    }

    func open(_ tab: ExpandedTab? = nil) {
        graceUntil = Date().addingTimeInterval(2.5)
        withAnimation(.islandOpen) {
            if let tab { selectedTab = tab }
            banner = nil
            pinnedOpen = true
        }
    }

    func close() {
        withAnimation(.islandClose) {
            pinnedOpen = false
            hovering = false
            hoverIntent = false
        }
    }
}

extension Animation {
    /// Öffnen: ein Hauch Überschwingen wie auf dem iPhone.
    static let islandOpen = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Schliessen: kritisch gedämpft, kein Nachwippen.
    static let islandClose = Animation.spring(response: 0.36, dampingFraction: 1.0)
    static let island = islandOpen
    static let islandSnappy = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let islandBouncy = Animation.spring(response: 0.45, dampingFraction: 0.62)
}

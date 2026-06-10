import SwiftUI
import Combine

/// Which panel is shown when the island is fully expanded.
enum ExpandedTab: String, CaseIterable, Identifiable {
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

/// A transient "live activity" peek — mirrors the iPhone's compact presentations.
enum IslandActivity: Equatable {
    case idle
    case charging(percent: Int, full: Bool)
    case mediaPeek
    case timerRunning
    case fileDrop
    case custom(symbol: String, text: String, tint: ColorToken)
}

/// A Codable-free color token so IslandActivity stays Equatable cheaply.
enum ColorToken: Equatable {
    case green, blue, orange, red, purple, white
    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .white: return .white
        }
    }
}

/// Central UI / morph state for the island.
final class IslandState: ObservableObject {
    @Published var hovering = false
    @Published var pinnedOpen = false        // clicked open, stays until clicked away
    @Published var selectedTab: ExpandedTab = .nowPlaying
    @Published var transientActivity: IslandActivity = .idle
    @Published var dragActive = false        // a file is hovering over the island

    private var clearWork: DispatchWorkItem?

    var isExpanded: Bool { hovering || pinnedOpen }

    /// Briefly present a live-activity peek, then fall back to idle.
    func flashActivity(_ activity: IslandActivity, duration: TimeInterval = 3.5) {
        clearWork?.cancel()
        withAnimation(.island) { transientActivity = activity }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.island) { self?.transientActivity = .idle }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

extension Animation {
    /// The signature springy morph, tuned to feel close to iOS.
    static let island = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let islandSnappy = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let islandBouncy = Animation.spring(response: 0.45, dampingFraction: 0.62)
}

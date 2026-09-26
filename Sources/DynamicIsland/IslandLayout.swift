import SwiftUI

/// Single source of truth for island sizing — shared by the SwiftUI view and the
/// AppKit hit-testing so the interactive region always matches what's drawn.
enum IslandLayout {
    static let expanded = CGSize(width: 440, height: 270)
    static let bannerHeight: CGFloat = 58

    /// Welche Grösse gerade gilt (Priorität wie auf dem iPhone).
    static func presentation(state: IslandState, media: MediaController, timer: TimerModel) -> IslandPresentation {
        if state.isExpanded { return .expanded }
        if state.banner != nil { return .banner }
        if resolvedPeek(state: state, media: media, timer: timer) != .idle { return .compact }
        if state.hoverIntent { return .lip }
        return .hidden
    }

    /// The transient/derived peek currently in effect (idle = nothing to show).
    static func resolvedPeek(state: IslandState, media: MediaController, timer: TimerModel) -> IslandActivity {
        if state.transientActivity != .idle { return state.transientActivity }
        if media.showMediaPeek { return .mediaPeek }   // on while playing; ~5 s grace after pause
        if timer.isRunning { return .timerRunning }
        if state.privacy.any, AppSettings.shared.showPrivacyIndicator {
            return .privacy(camera: state.privacy.camera, mic: state.privacy.mic)
        }
        return .idle
    }

    static func collapsed(_ m: NotchMetrics) -> CGSize {
        CGSize(width: m.notchWidth, height: m.notchHeight)
    }

    /// Breite der kompakten Darstellung je nach Inhalt – Kamera-Punkt klein,
    /// HUD-Balken breit (Apple: „ohne verschwendeten Platz“).
    static func compact(_ m: NotchMetrics, for kind: IslandActivity) -> CGSize {
        let extra: CGFloat
        switch kind {
        case .privacy:              extra = 92
        case .unlocked:             extra = 100
        case .volume, .brightness:  extra = 210
        case .custom:               extra = 200
        default:                    extra = 168
        }
        return CGSize(width: min(expanded.width - 20, m.notchWidth + extra), height: m.notchHeight)
    }

    static func banner(_ m: NotchMetrics) -> CGSize {
        CGSize(width: max(m.notchWidth + 190, 370), height: m.notchHeight + bannerHeight)
    }

    static func size(for p: IslandPresentation, state: IslandState,
                     media: MediaController, timer: TimerModel) -> CGSize {
        let m = state.metrics
        switch p {
        case .hidden:   return collapsed(m)
        case .lip:      return CGSize(width: m.notchWidth + 18, height: m.notchHeight + 5)
        case .compact:  return compact(m, for: resolvedPeek(state: state, media: media, timer: timer))
        case .banner:   return banner(m)
        case .expanded: return expanded
        }
    }

    static func currentSize(state: IslandState, media: MediaController, timer: TimerModel) -> CGSize {
        size(for: presentation(state: state, media: media, timer: timer), state: state, media: media, timer: timer)
    }

    /// Size the floating panel to the maximum bounding box plus a little breathing room
    /// (Platz für Schatten und das Überschwingen der Feder).
    static var panelSize: CGSize {
        CGSize(width: expanded.width + 80, height: expanded.height + 40)
    }
}

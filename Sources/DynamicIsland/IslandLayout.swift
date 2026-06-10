import SwiftUI

/// Single source of truth for island sizing — shared by the SwiftUI view and the
/// AppKit hit-testing so the interactive region always matches what's drawn.
enum IslandLayout {
    static let expanded = CGSize(width: 440, height: 270)

    static func collapsed(_ m: NotchMetrics) -> CGSize {
        CGSize(width: m.notchWidth, height: m.notchHeight)
    }

    static func peek(_ m: NotchMetrics) -> CGSize {
        // Match the notch height exactly so the peek never hangs below the menu
        // bar into other apps.
        CGSize(width: min(expanded.width - 20, m.notchWidth + 168),
               height: m.notchHeight)
    }

    /// The transient/derived peek currently in effect (idle = nothing to show).
    static func resolvedPeek(state: IslandState, media: MediaController, timer: TimerModel) -> IslandActivity {
        if state.transientActivity != .idle { return state.transientActivity }
        if media.showMediaPeek { return .mediaPeek }   // on while playing; ~5 s grace after pause
        if timer.isRunning { return .timerRunning }
        return .idle
    }

    static func currentSize(state: IslandState, metrics: NotchMetrics,
                            media: MediaController, timer: TimerModel) -> CGSize {
        if state.isExpanded { return expanded }
        if resolvedPeek(state: state, media: media, timer: timer) != .idle { return peek(metrics) }
        return collapsed(metrics)
    }

    /// Size the floating panel to the maximum bounding box plus a little breathing room.
    static var panelSize: CGSize {
        CGSize(width: expanded.width + 80, height: expanded.height + 40)
    }
}

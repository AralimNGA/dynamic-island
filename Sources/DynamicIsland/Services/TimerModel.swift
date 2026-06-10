import Foundation
import Combine

/// A simple stopwatch + countdown timer that drives a live activity.
final class TimerModel: ObservableObject {
    enum Mode { case stopwatch, countdown }

    @Published var mode: Mode = .countdown
    @Published var isRunning = false
    @Published var display: TimeInterval = 0     // value currently shown (seconds)

    /// Called when a countdown reaches zero.
    var onFinished: (() -> Void)?
    /// Called whenever the timer starts running (to trigger a peek).
    var onStart: (() -> Void)?

    private var ticker: Timer?
    private var anchor: Date?           // reference point in time
    private var baseValue: TimeInterval = 0   // accumulated before current run

    var isActive: Bool { isRunning || display > 0 }

    // MARK: - Controls

    func startCountdown(seconds: TimeInterval) {
        mode = .countdown
        baseValue = seconds
        display = seconds
        run()
        onStart?()
    }

    func startStopwatch() {
        mode = .stopwatch
        baseValue = 0
        display = 0
        run()
        onStart?()
    }

    func toggle() {
        if isRunning { pause() } else { run() }
    }

    func pause() {
        guard isRunning else { return }
        baseValue = display
        anchor = nil
        isRunning = false
        ticker?.invalidate()
        ticker = nil
    }

    func reset() {
        pause()
        display = mode == .countdown ? baseValue : 0
        if mode == .stopwatch { baseValue = 0; display = 0 }
    }

    func stop() {
        pause()
        baseValue = 0
        display = 0
    }

    // MARK: - Internals

    private func run() {
        guard !isRunning else { return }
        anchor = Date()
        isRunning = true
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard let anchor else { return }
        let delta = Date().timeIntervalSince(anchor)
        switch mode {
        case .stopwatch:
            display = baseValue + delta
        case .countdown:
            display = max(0, baseValue - delta)
            if display <= 0 {
                stop()
                onFinished?()
            }
        }
    }
}

extension TimeInterval {
    /// Formats as M:SS or H:MM:SS.
    var clockString: String {
        let total = Int(rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

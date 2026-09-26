import SwiftUI

/// The split-lobe "live activity" peek shown around the physical notch.
struct CompactPeek: View {
    let kind: IslandActivity
    @ObservedObject var media: MediaController
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var timer: TimerModel
    let notchWidth: CGFloat
    let lobeHeight: CGFloat
    var sidePadding: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            leftLobe
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
                .frame(width: notchWidth)        // gap over the physical notch
            rightLobe
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, sidePadding)
        .frame(maxHeight: .infinity)
    }

    // MARK: Left lobe

    @ViewBuilder private var leftLobe: some View {
        switch kind {
        case .mediaPeek:
            ArtworkView(image: media.artwork, accent: media.accent, cornerRadius: 5)
                .frame(width: lobeHeight - 10, height: lobeHeight - 10)
        case .charging(_, let full):
            icon(full ? "battery.100percent.bolt" : "bolt.fill", .green)
                .symbolEffect(.pulse, options: .repeating, isActive: !full)
        case .lowBattery(let p):
            icon(p <= 10 ? "battery.0percent" : "battery.25percent", .red)
        case .timerRunning:
            icon("timer", .orange)
        case .fileDrop:
            icon("tray.and.arrow.down.fill", .cyan)
        case .volume(let level, let muted, let symbol):
            icon(symbol.isEmpty ? Self.speakerSymbol(level: level, muted: muted) : symbol, .white)
                .contentTransition(.symbolEffect(.replace))
        case .brightness(let level):
            icon(level < 0.5 ? "sun.min.fill" : "sun.max.fill", .white)
                .contentTransition(.symbolEffect(.replace))
        case .unlocked:
            icon("lock.open.fill", .white)
                .symbolEffect(.bounce, value: kind)
        case .privacy(let camera, _):
            icon(camera ? "video.fill" : "mic.fill", camera ? .green : .orange)
        case .custom(let symbol, _, let tint):
            icon(symbol, tint.color)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Right lobe

    @ViewBuilder private var rightLobe: some View {
        switch kind {
        case .mediaPeek:
            AudioBars(active: media.isPlaying, color: media.accent, barCount: 4)
                .frame(width: 20, height: lobeHeight - 16)
        case .charging(let percent, _):
            label("\(percent) %", .white)
        case .lowBattery(let p):
            label("\(p) %", .red)
        case .timerRunning:
            Text(timer.display.clockString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
                .contentTransition(.numericText(countsDown: timer.mode == .countdown))
        case .fileDrop:
            label("Ablegen", .white.opacity(0.9))
        case .volume(let level, let muted, _):
            LevelBar(level: muted ? 0 : level)
        case .brightness(let level):
            LevelBar(level: level)
        case .unlocked:
            EmptyView()
        case .privacy(let camera, _):
            PulsingDot(color: camera ? .green : .orange)
        case .custom(_, let text, _):
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        case .idle:
            EmptyView()
        }
    }

    private func icon(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
    }

    private func label(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
            .contentTransition(.numericText())
    }

    static func speakerSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Schmaler Pegel-Balken für Lautstärke/Helligkeit (wie das iOS-HUD).
struct LevelBar: View {
    let level: Double
    var width: CGFloat = 64

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
            Capsule().fill(.white)
                .frame(width: max(0, min(1, level)) * width)
        }
        .frame(width: width, height: 6)
        .animation(.islandSnappy, value: level)
    }
}

/// Pulsierender Punkt (Kamera-/Mikrofon-Indikator).
struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.8), radius: on ? 4 : 1)
            .opacity(on ? 1 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

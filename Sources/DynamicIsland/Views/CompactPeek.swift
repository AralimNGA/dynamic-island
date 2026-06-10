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
                .frame(width: lobeHeight - 8, height: lobeHeight - 8)
        case .charging(_, let full):
            Image(systemName: full ? "battery.100.bolt" : "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.green)
        case .timerRunning:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        case .fileDrop:
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.cyan)
        case .custom(let symbol, _, let tint):
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.color)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Right lobe

    @ViewBuilder private var rightLobe: some View {
        switch kind {
        case .mediaPeek:
            AudioBars(active: media.isPlaying, color: media.accent, barCount: 4)
                .frame(width: 20, height: lobeHeight - 14)
        case .charging(let percent, _):
            Text("\(percent)%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        case .timerRunning:
            Text(timer.display.clockString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        case .fileDrop:
            Text("Ablegen")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        case .custom(_, let text, _):
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        case .idle:
            EmptyView()
        }
    }
}

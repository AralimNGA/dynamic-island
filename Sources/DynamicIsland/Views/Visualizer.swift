import SwiftUI

/// Animated audio bars. Pauses (no redraws) when inactive to keep idle CPU ~0%.
struct AudioBars: View {
    var active: Bool
    var color: Color
    var barCount: Int = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let gap: CGFloat = 2
                let barWidth = max(2, (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))

                for i in 0..<barCount {
                    let phase = Double(i) * 0.9
                    let amplitude: CGFloat = active
                        ? CGFloat(0.30 + 0.70 * abs(sin(now * 6.0 + phase)))
                        : 0.28
                    let barH = max(barWidth, size.height * amplitude)
                    let x = CGFloat(i) * (barWidth + gap)
                    let y = (size.height - barH) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
        }
    }
}

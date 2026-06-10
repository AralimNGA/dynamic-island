import SwiftUI

/// Album artwork with a graceful gradient fallback derived from the accent color.
struct ArtworkView: View {
    let image: NSImage?
    let accent: Color
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [accent.opacity(0.9), accent.opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Horizontally scrolling text for long titles (a gentle marquee).
struct Marquee: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    var color: Color = .white

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    /// True only when the text is too long to fit (then it scrolls + fades).
    private var overflowing: Bool { textWidth > containerWidth + 4 }

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(widthReader)
                .offset(x: offset)
                .onAppear { containerWidth = geo.size.width; restart() }
                .onChange(of: text) { restart() }
                .onChange(of: geo.size.width) { containerWidth = geo.size.width; restart() }
        }
        .clipped()
        .mask(edgeMask)
    }

    /// Fade the edges only while scrolling — otherwise show the whole text so the
    /// first letter is never hidden behind the leading gradient.
    @ViewBuilder private var edgeMask: some View {
        if overflowing {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        } else {
            Color.black
        }
    }

    private var widthReader: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { textWidth = g.size.width; restart() }
                .onChange(of: text) { textWidth = g.size.width; restart() }
        }
    }

    private func restart() {
        guard textWidth > 0, containerWidth > 0 else { offset = 0; return }
        if overflowing {
            offset = 0
            let distance = textWidth - containerWidth + 8
            withAnimation(.linear(duration: Double(distance) / 30.0).delay(1.2).repeatForever(autoreverses: true)) {
                offset = -distance
            }
        } else {
            // Short enough to fit → center it (and stop any running scroll).
            withAnimation(.easeOut(duration: 0.12)) {
                offset = (containerWidth - textWidth) / 2
            }
        }
    }
}

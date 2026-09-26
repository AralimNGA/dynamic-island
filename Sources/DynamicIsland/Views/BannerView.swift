import SwiftUI

/// Mitteilung unter der Notch: neuer Titel, Kopfhörer verbunden, Timer fertig …
struct BannerView: View {
    let banner: IslandBanner
    @ObservedObject var media: MediaController
    let topInset: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.top, topInset + 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch banner {
        case .track: return media.info.title
        case .device(let name, _, _): return name
        case .message(_, let title, _, _): return title
        }
    }

    private var subtitle: String {
        switch banner {
        case .track: return media.info.artist.isEmpty ? media.info.app : media.info.artist
        case .device: return "Verbunden"
        case .message(_, _, let subtitle, _): return subtitle
        }
    }

    @ViewBuilder private var leading: some View {
        switch banner {
        case .track:
            ArtworkView(image: media.artwork, accent: media.accent, cornerRadius: 9)
                .frame(width: 40, height: 40)
                .shadow(color: media.accent.opacity(0.45), radius: 6, y: 2)
        case .device(_, let symbol, _):
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .symbolEffect(.bounce, value: banner)
        case .message(let symbol, _, _, let tint):
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint.color)
                .frame(width: 40, height: 40)
                .background(Circle().fill(tint.color.opacity(0.18)))
                .symbolEffect(.bounce, value: banner)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch banner {
        case .track:
            AudioBars(active: media.isPlaying, color: media.accent, barCount: 4)
                .frame(width: 22, height: 18)
        case .device(_, _, let readings):
            HStack(spacing: 8) {
                ForEach(readings, id: \.label) { r in
                    BatteryRing(label: r.label, percent: r.percent, charging: false, dimmed: false)
                        .scaleEffect(0.8)
                }
            }
        case .message:
            EmptyView()
        }
    }
}

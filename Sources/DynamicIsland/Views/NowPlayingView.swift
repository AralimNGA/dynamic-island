import SwiftUI

/// The expanded music player panel.
struct NowPlayingView: View {
    @ObservedObject var media: MediaController
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragging = false
    @State private var dragFrac: Double = 0

    var body: some View {
        if media.hasTrack {
            if media.info.isBrowser && !media.info.canSeek {
                browserDisplay          // video without JS — centered, fills the space
            } else {
                standardPlayer          // music + browser-with-JS
            }
        } else if media.permissionDenied {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange.opacity(0.8))
                Text("Steuerung blockiert")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Automation erlauben")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.4))
                Text(media.anyAppRunning ? "Nichts läuft" : "Keine Musik")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(media.anyAppRunning ? "Wiedergabe in Spotify/Music starten" : "Spotify oder Music starten")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Music and browser-with-JS: artwork on the left, controls below.
    private var standardPlayer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ArtworkView(image: media.artwork, accent: media.accent,
                            cornerRadius: media.info.isBrowser ? 7 : 8)
                    .frame(width: media.info.isBrowser ? 84 : 58,
                           height: media.info.isBrowser ? 48 : 58)
                    .shadow(color: media.accent.opacity(0.5), radius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Marquee(text: media.info.title, font: .system(size: 14, weight: .semibold))
                        .frame(height: 18)
                    Text(media.info.artist.isEmpty ? media.info.album : media.info.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    sourceBadge
                }
                Spacer(minLength: 0)
            }

            scrubber

            HStack(spacing: media.info.isBrowser ? 12 : 18) {
                if media.info.app == "Spotify" {
                    toggleButton("shuffle", active: media.info.shuffling) { media.toggleShuffle() }
                }
                if media.info.isBrowser {
                    controlButton("backward.end.fill", size: 13) { media.skipPrevious() }
                }
                controlButton(media.info.isBrowser ? "gobackward.10" : "backward.fill", size: 15) { media.previous() }
                controlButton(media.isPlaying ? "pause.fill" : "play.fill", size: 22) { media.playPause() }
                controlButton(media.info.isBrowser ? "goforward.10" : "forward.fill", size: 15) { media.next() }
                if media.info.isBrowser {
                    controlButton("forward.end.fill", size: 13) { media.skipNext() }
                }
                if !media.info.isBrowser { repeatButton }
            }
            .foregroundStyle(.white)

            if media.info.app == "Spotify", !settings.playlists.isEmpty {
                Menu {
                    ForEach(settings.playlists) { pl in
                        Button(pl.name) { media.playURI(pl.uri) }
                    }
                } label: {
                    Label("Playlist wechseln", systemImage: "music.note.list")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(media.accent)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    /// Browser video without JS control: a big centered thumbnail in the free space.
    private var browserDisplay: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ArtworkView(image: media.artwork, accent: media.accent, cornerRadius: 10)
                .frame(width: 148, height: 83)            // 16:9, cropped to the video frame
                .shadow(color: media.accent.opacity(0.45), radius: 9, y: 3)
            VStack(spacing: 4) {
                Marquee(text: media.info.title, font: .system(size: 14, weight: .semibold))
                    .frame(height: 18)
                    .frame(maxWidth: 320)
                HStack(spacing: 5) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 9, weight: .bold))
                    Text(media.info.album.isEmpty ? media.info.artist : media.info.album)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(media.accent)
            }
            Text("Läuft im Browser · für Steuerung JavaScript aus Apple Events aktivieren")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceBadge: some View {
        let i = media.info
        let icon = i.isBrowser ? "play.rectangle.fill" : (i.app == "Spotify" ? "waveform" : "music.note")
        let label = i.isBrowser ? (i.album.isEmpty ? i.app : i.album) : i.app
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(media.accent)
    }

    private var scrubber: some View {
        let dur = media.info.duration
        let liveFrac = dur > 0 ? min(1, max(0, media.info.position / dur)) : 0
        let frac = dragging ? dragFrac : liveFrac
        return VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(media.accent).frame(width: w * frac, height: 4)
                    Circle().fill(.white)
                        .frame(width: dragging ? 13 : 9, height: dragging ? 13 : 9)
                        .offset(x: max(0, w * frac - (dragging ? 6.5 : 4.5)))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragging = true
                            dragFrac = min(1, max(0, v.location.x / w))
                        }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / w))
                            dragging = false
                            if dur > 0 { media.seek(to: f * dur) }
                        }
                )
            }
            .frame(height: 16)
            HStack {
                Text((dragging ? dragFrac * dur : media.info.position).clockString)
                Spacer()
                Text(dur.clockString)
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: active ? "\(symbol).circle.fill" : symbol)
                .font(.system(size: active ? 18 : 13, weight: .semibold))
                .foregroundStyle(active ? media.accent : .white.opacity(0.32))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? media.accent.opacity(0.22) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active ? "An" : "Aus")
    }

    /// Cycles off → Playlist (repeat all) → Song (repeat one) → off.
    private var repeatButton: some View {
        let mode = media.repeatMode
        let active = mode != .off
        let icon = mode == .one ? "repeat.1.circle.fill" : (mode == .all ? "repeat.circle.fill" : "repeat")
        return Button { media.cycleRepeat() } label: {
            Image(systemName: icon)
                .font(.system(size: active ? 18 : 13, weight: .semibold))
                .foregroundStyle(active ? media.accent : .white.opacity(0.32))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? media.accent.opacity(0.22) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .one ? "Song wiederholen" : (mode == .all ? "Playlist wiederholen" : "Wiederholen aus"))
    }
}

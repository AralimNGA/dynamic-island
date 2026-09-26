import SwiftUI

/// Startseite der offenen Island: das Wichtigste auf einen Blick
/// (Musik links, Termin + Status rechts) – wie die Hauptseite von NotchNook/Alcove.
struct HomeView: View {
    let services: IslandServices
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarService
    @ObservedObject var timer: TimerModel
    @ObservedObject var weather: WeatherService
    @ObservedObject var battery: BatteryMonitor

    init(services: IslandServices) {
        self.services = services
        media = services.media
        calendar = services.calendar
        timer = services.timer
        weather = services.weather
        battery = services.battery
    }

    var body: some View {
        HStack(spacing: 8) {
            mediaCard
            VStack(spacing: 8) {
                eventCard
                statusCard
            }
            .frame(width: 138)
        }
        .padding(.vertical, 4)
        .onAppear {
            calendar.refresh()
            weather.refreshIfStale()
        }
    }

    // MARK: Musik

    private var mediaCard: some View {
        Card(tint: media.hasTrack ? media.accent : nil) {
            if media.hasTrack {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ArtworkView(image: media.artwork, accent: media.accent, cornerRadius: 10)
                            .frame(width: media.info.isBrowser ? 84 : 56, height: 56)
                            .shadow(color: media.accent.opacity(0.5), radius: 8, y: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Marquee(text: media.info.title, font: .system(size: 13, weight: .semibold), leading: true)
                                .frame(height: 17)
                            Text(media.info.artist.isEmpty ? media.info.app : media.info.artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                            AudioBars(active: media.isPlaying, color: media.accent, barCount: 5)
                                .frame(width: 22, height: 12)
                                .padding(.top, 2)
                        }
                    }
                    progress
                    HStack(spacing: 26) {
                        control("backward.fill", 15) { media.previous() }
                        control(media.isPlaying ? "pause.fill" : "play.fill", 22) { media.playPause() }
                            .contentTransition(.symbolEffect(.replace))
                        control("forward.fill", 15) { media.next() }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.white)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Keine Wiedergabe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 8) {
                        launch("Spotify", "com.spotify.client")
                        launch("Musik", "com.apple.Music")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var progress: some View {
        let dur = media.info.duration
        let frac = dur > 0 ? min(1, max(0, media.info.position / dur)) : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(media.accent).frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 3)
        .opacity(dur > 0 ? 1 : 0)
        .animation(.linear(duration: 1.2), value: frac)
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size + 12, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func launch(_ title: String, _ bundle: String) -> some View {
        Button {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Termin

    private var eventCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                Label("Als Nächstes", systemImage: "calendar")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.9))
                if let e = calendar.nextEvent {
                    Text(e.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(e.when)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                } else {
                    Text(calendar.calendarRunning || !calendar.loaded ? "Keine Termine" : "Kalender geschlossen")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture { services.state.selectedTab = .calendar }
    }

    // MARK: Status (Timer, Wetter, Akku)

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if timer.isActive {
                    HStack(spacing: 6) {
                        Image(systemName: "timer").foregroundStyle(.orange)
                        Text(timer.display.clockString)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                } else if let w = weather.weather {
                    HStack(spacing: 6) {
                        Image(systemName: WeatherService.symbol(for: w.code))
                            .symbolRenderingMode(.multicolor)
                        Text("\(w.temp)°")
                            .foregroundStyle(.white)
                        Text(w.city)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                HStack(spacing: 6) {
                    Image(systemName: battery.isPluggedIn ? "battery.100percent.bolt" : "battery.75percent")
                        .foregroundStyle(battery.isPluggedIn ? .green : (battery.percent <= 20 ? .red : .white.opacity(0.8)))
                    Text("\(battery.percent) %")
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                    if battery.isCharging, battery.timeToFull > 0 {
                        Text("· \(battery.timeToFull / 60):\(String(format: "%02d", battery.timeToFull % 60))")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Dezente Karte im Island-Stil (konzentrische Rundung zur Island).
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: [tint.opacity(0.22), .clear],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
            }
    }
}

/// Knopf, der beim Drücken leicht nachgibt.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.islandSnappy, value: configuration.isPressed)
    }
}

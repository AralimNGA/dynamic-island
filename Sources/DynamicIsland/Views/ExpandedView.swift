import SwiftUI
import EventKit

/// The fully-expanded panel with a tab bar at the bottom.
struct ExpandedView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var media: MediaController
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var timer: TimerModel
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var calendar: CalendarService
    @ObservedObject var claude: ClaudeService
    @ObservedObject var camera: CameraController
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var todo: TodoModel
    @ObservedObject var weather: WeatherService
    @ObservedObject var stocks: StockService
    @ObservedObject var deviceBattery: DeviceBatteryService
    @ObservedObject private var settings = AppSettings.shared
    let topInset: CGFloat

    private func fixTab() {
        if !settings.isEnabled(state.selectedTab), let first = settings.orderedEnabledTabs.first {
            state.selectedTab = first
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(state.selectedTab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .openIslandSettings, object: nil)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Einstellungen")
                StatusPill(battery: battery)
            }
            .frame(height: 16)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(state.selectedTab)

            TabBar(selected: $state.selectedTab) { tab in
                if tab == .calendar { calendar.refresh() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, topInset)
        .padding(.bottom, 10)
        .onAppear { fixTab() }
        .onChange(of: settings.enabledTabs) { fixTab() }
    }

    @ViewBuilder private var content: some View {
        switch state.selectedTab {
        case .nowPlaying: NowPlayingView(media: media)
        case .claude:     ClaudeView(claude: claude)
        case .mirror:     MirrorView(camera: camera)
        case .recorder:   RecorderView(rec: recorder)
        case .shelf:      ShelfView(shelf: shelf, state: state)
        case .timer:      TimerView(timer: timer)
        case .todo:       TodoView(todo: todo)
        case .weather:    WeatherView(weather: weather)
        case .stocks:     StockView(stocks: stocks)
        case .devices:    DeviceBatteryView(devices: deviceBattery, battery: battery)
        case .calendar:   CalendarPane(calendar: calendar)
        }
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @Binding var selected: ExpandedTab
    var onSelect: (ExpandedTab) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            ForEach(settings.orderedEnabledTabs) { tab in
                Button {
                    withAnimation(.islandSnappy) { selected = tab }
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected == tab ? .white.opacity(0.16) : .clear)
                        )
                        .foregroundStyle(selected == tab ? .white : .white.opacity(0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.05)))
    }
}

// MARK: - Status pill (clock + battery)

struct StatusPill: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 3) {
                Image(systemName: batterySymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(battery.isPluggedIn ? .green : .white.opacity(0.85))
                Text("\(battery.percent)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var batterySymbol: String {
        if battery.isPluggedIn { return "battery.100.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }
}

// MARK: - Timer pane

struct TimerView: View {
    @ObservedObject var timer: TimerModel

    private let presets: [(String, TimeInterval)] = [
        ("1m", 60), ("3m", 180), ("5m", 300), ("10m", 600),
    ]

    var body: some View {
        VStack(spacing: 10) {
            Text(timer.display.clockString)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            if timer.isActive {
                HStack(spacing: 22) {
                    iconButton(timer.isRunning ? "pause.fill" : "play.fill") { timer.toggle() }
                    iconButton("stop.fill") { timer.stop() }
                }
                .foregroundStyle(.white)
            } else {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { preset in
                        Button {
                            timer.startCountdown(seconds: preset.1)
                        } label: {
                            Text(preset.0)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 42, height: 28)
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    timer.startStopwatch()
                } label: {
                    Label("Stoppuhr", systemImage: "stopwatch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar pane

struct CalendarPane: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { calendar.refresh() }
    }

    @ViewBuilder private var content: some View {
        if calendar.permissionDenied {
            info("lock.fill", .orange, "Kalenderzugriff blockiert", button: "Automation erlauben") {
                calendar.openSettings()
            }
        } else if calendar.loaded && !calendar.calendarRunning {
            info("calendar.badge.exclamationmark", .white.opacity(0.4),
                 "Kalender-App ist nicht geöffnet", button: "Kalender öffnen") {
                calendar.openCalendarApp()
            }
        } else if calendar.loading {
            ProgressView().controlSize(.small)
        } else if let event = calendar.nextEvent {
            VStack(alignment: .leading, spacing: 6) {
                Text("Als Nächstes")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(event.when)
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                if !event.location.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                        Text(event.location).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.green.opacity(0.7))
                Text("Keine Termine in den nächsten Tagen")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func info(_ icon: String, _ tint: Color, _ text: String,
                      button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }
}

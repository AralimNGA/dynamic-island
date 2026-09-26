import SwiftUI

// MARK: - Weather

struct WeatherView: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        Group {
            if let w = weather.weather {
                VStack(spacing: 3) {
                    Image(systemName: WeatherService.symbol(for: w.code))
                        .font(.system(size: 36))
                        .symbolRenderingMode(.multicolor)
                    Text("\(w.temp)°")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(WeatherService.text(for: w.code))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(w.city) · Wind \(w.wind) km/h")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else if weather.loading {
                ProgressView().controlSize(.small)
            } else {
                placeholder("cloud.sun", weather.error ?? "Wetter laden") { weather.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { weather.refreshIfStale() }
    }
}

// MARK: - Stocks

struct StockView: View {
    @ObservedObject var stocks: StockService
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if !stocks.quotes.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(stocks.quotes) { row($0) }
                    }
                }
            } else if stocks.loading {
                ProgressView().controlSize(.small)
            } else {
                placeholder("chart.line.uptrend.xyaxis", stocks.error ?? "Aktien laden") {
                    stocks.refresh(symbols: settings.stockSymbols)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { stocks.refreshIfStale(symbols: settings.stockSymbols) }
    }

    private func row(_ q: StockService.Quote) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(q.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(q.name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.2f", q.price) + currencySuffix(q.currency))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(String(format: "%+.2f%%", q.changePct))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(q.changePct >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.05)))
    }

    private func currencySuffix(_ c: String) -> String {
        switch c { case "USD": return " $"; case "EUR": return " €"; case "GBP": return " £"; default: return " " + c }
    }
}

// MARK: - Device battery

struct DeviceBatteryView: View {
    @ObservedObject var devices: DeviceBatteryService
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var remote: RemoteBatteryService
    @ObservedObject var store: RemoteBatteryStore
    @ObservedObject private var settings = AppSettings.shared

    init(devices: DeviceBatteryService, battery: BatteryMonitor, remote: RemoteBatteryService) {
        self.devices = devices
        self.battery = battery
        self.remote = remote
        self.store = remote.store
    }

    /// Weitere Geräte ohne die, die gerade direkt am Mac hängen (die stehen oben, genau).
    private var others: [RemoteBatteryStore.Entry] {
        let connectedNames = Set(devices.devices.filter(\.connected).map(\.name))
        return store.entries.filter { !connectedNames.contains($0.key.name) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Jede Minute neu zeichnen, damit „vor X Min.“ weiterläuft (nur solange sichtbar).
            TimelineView(.everyMinute) { ctx in
                list(now: ctx.date)
            }
        }
        .defaultScrollAnchor(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            devices.refresh()
            remote.refreshAll()
        }
    }

    private func list(now: Date) -> some View {
        VStack(spacing: 5) {
            row(symbol: "laptopcomputer", name: "Dieser Mac", detail: nil,
                readings: [("", battery.percent, battery.isPluggedIn)], active: true)
            ForEach(devices.devices.filter(\.connected)) { d in
                row(symbol: d.symbol, name: d.name, detail: "verbunden",
                    readings: d.readings.map { ($0.label, $0.percent, false) }, active: true)
            }

            if !others.isEmpty {
                sectionHeader("Weitere Geräte")
                ForEach(others) { e in
                    row(symbol: e.symbol, name: e.displayName, detail: detail(for: e, now: now),
                        // Ladezustand pro Teil (L/R/Case); bei veralteten Werten keinen Blitz.
                        readings: e.parts.map { ($0.label, $0.percent, $0.charging == true && !e.stale) },
                        active: !e.stale)
                }
            }
            // Früher verbundenes Zubehör (Magic Mouse …), das keine andere Quelle hat.
            ForEach(devices.devices.filter { !$0.connected && !others.map(\.key.name).contains($0.name) }) { d in
                row(symbol: d.symbol, name: d.name,
                    detail: d.lastSeen.map { "zuletzt " + Self.relative($0, now: now) },
                    readings: d.readings.map { ($0.label, $0.percent, false) }, active: false)
            }

            bluetoothHint
            lockdownHint
            if others.isEmpty, devices.devices.isEmpty, !devices.loading {
                footnote("iPhone, iPad und AirPods in der Nähe erscheinen hier nach kurzer Zeit.")
            }

            Button { devices.refresh(); remote.refreshAll() } label: {
                Label(devices.loading ? "Lädt …" : "Aktualisieren", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .disabled(devices.loading)
            .padding(.top, 2)
        }
    }

    /// Hinweis zur Kabel-Kopplung: konkret, wenn ein Gerät dem Mac nicht vertraut,
    /// allgemein, solange noch kein iPhone/iPad genaue Werte liefert.
    @ViewBuilder private var lockdownHint: some View {
        if settings.remoteBatteryLockdown {
            let untrusted = remote.lockdownStatus.filter { $0.value == .notTrusted }.map(\.key).sorted()
            let hasExact = others.contains { $0.precision == .exact && ($0.key.kind == .iPhone || $0.key.kind == .iPad) }
            if !untrusted.isEmpty {
                footnote("„\(untrusted.joined(separator: "“, „"))“ vertraut diesem Mac noch nicht – entsperren und „Vertrauen“ tippen.")
            } else if !hasExact, !others.isEmpty, !remote.lockdownStatus.values.contains(.ok) {
                footnote("Genaue Werte und Apple Watch: iPhone/iPad einmal per Kabel an diesen Mac anschliessen, „Vertrauen“ tippen und im Finder „Im WLAN anzeigen“ aktivieren.")
            }
        }
    }

    // MARK: Teile

    @ViewBuilder private var bluetoothHint: some View {
        switch remote.bluetoothState {
        case .off, .notDetermined:
            Button { remote.enableBluetooth() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "airpodspro")
                    Text("AirPods am iPhone anzeigen – Bluetooth erlauben")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.blue.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
        case .denied:
            footnote("Bluetooth-Zugriff fehlt – Systemeinstellungen › Datenschutz & Sicherheit › Bluetooth")
        case .enabled:
            EmptyView()
        }
    }

    private func detail(for e: RemoteBatteryStore.Entry, now: Date) -> String {
        let age = Self.age(e.observedAt, now: now)
        let how: String
        switch e.precision {
        case .bucket4: how = "≈ Grobwert"
        case .step10: how = "≈ 10-%-Schritte"
        case .exact: how = e.source == .companionProxy ? "über iPhone" : "genau"
        }
        return "\(how) · \(age)"
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4).padding(.leading, 4)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3).padding(.horizontal, 6)
    }

    private func row(symbol: String, name: String, detail: String?,
                     readings: [(label: String, percent: Int, charging: Bool)], active: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(active ? 0.85 : 0.4))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.6)).lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                ForEach(Array(readings.enumerated()), id: \.offset) { _, r in
                    BatteryRing(label: r.label, percent: r.percent, charging: r.charging, dimmed: !active)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 90 { return "gerade eben" }
        if secs < 3600 { return "vor \(Int(secs / 60)) Min." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'zuletzt' HH:mm" : "'zuletzt am' dd.MM."
        return f.string(from: date)
    }

    private static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
}

/// Apple-style circular battery gauge.
struct BatteryRing: View {
    let label: String
    let percent: Int
    let charging: Bool
    let dimmed: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.14), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(percent)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: 32, height: 32)
            // Laden: kleines Blitz-Abzeichen oben rechts, die Prozentzahl bleibt sichtbar.
            .overlay(alignment: .topTrailing) {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(.green))
                        .offset(x: 3, y: -3)
                }
            }
            .opacity(dimmed ? 0.55 : 1)
            if !label.isEmpty {
                Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var color: Color {
        if percent <= 15 { return .red }
        if percent <= 30 { return .orange }
        return .green
    }
}

// MARK: - Shared placeholder

private func placeholder(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        Button(action: action) {
            Text("Aktualisieren")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

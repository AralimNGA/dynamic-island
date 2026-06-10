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

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                row(symbol: "laptopcomputer", name: "Dieser Mac",
                    readings: [("", battery.percent)], connected: true,
                    charging: battery.isPluggedIn, lastSeen: nil)
                ForEach(devices.devices) { d in
                    row(symbol: d.symbol, name: d.name,
                        readings: d.readings.map { ($0.label, $0.percent) },
                        connected: d.connected, charging: false, lastSeen: d.lastSeen)
                }
                if devices.devices.isEmpty && !devices.loading {
                    Text("AirPods & Magic-Geräte erscheinen hier, sobald sie einmal mit dem Mac verbunden waren.")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                Button { devices.refresh() } label: {
                    Label(devices.loading ? "Lädt…" : "Aktualisieren", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(devices.loading)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { devices.refresh() }
    }

    private func row(symbol: String, name: String, readings: [(String, Int)],
                     connected: Bool, charging: Bool, lastSeen: Date?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(connected ? 0.85 : 0.4))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12))
                    .foregroundStyle(.white.opacity(connected ? 1 : 0.6)).lineLimit(1)
                if !connected, let lastSeen {
                    Text("zuletzt \(Self.relative(lastSeen))")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 7) {
                ForEach(Array(readings.enumerated()), id: \.offset) { _, r in
                    BatteryRing(label: r.0, percent: r.1, charging: charging, dimmed: !connected)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
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
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green)
                } else {
                    Text("\(percent)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 32, height: 32)
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

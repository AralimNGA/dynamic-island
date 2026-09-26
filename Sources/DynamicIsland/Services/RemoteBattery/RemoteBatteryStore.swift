import Foundation
import Combine

/// Führt die Werte aller Quellen zusammen: pro Gerät gewinnt die genaueste
/// frische Quelle, sonst der neueste Wert (als „veraltet“ markiert).
/// Werte bleiben 14 Tage sichtbar – wie Apples Batterien-Widget. Nur Main-Thread.
final class RemoteBatteryStore: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let key: RemoteDeviceKey
        let displayName: String
        let symbol: String
        let parts: [BatteryPart]
        let precision: BatteryPrecision
        let source: BatterySource
        let observedAt: Date
        let stale: Bool
        var id: RemoteDeviceKey { key }
    }

    @Published private(set) var entries: [Entry] = []
    /// Für Test-Renderings aus: Demo-Werte nicht in den echten Speicher schreiben.
    var persistenceEnabled = true

    private var samples: [RemoteDeviceKey: [BatterySource: BatterySample]] = [:]
    /// Wann jeder AirPods-Teil (L/R/Case) zuletzt *direkt* gemeldet wurde.
    private var slotSeen: [RemoteDeviceKey: [BatteryPart.Slot: Date]] = [:]
    private let cacheKey = "remoteBatteryCache.v1"
    private let retention: TimeInterval = 14 * 24 * 3600
    private var saveWork: DispatchWorkItem?

    init() {
        load()
        rebuild()
        // Modellname kam im Hintergrund an (Xcode-Datenbank) → Anzeige neu aufbauen.
        DeviceNames.onNameResolved = { [weak self] in self?.refreshAges() }
    }

    private static let debug = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"

    func ingest(_ s: BatterySample) {
        if Self.debug {
            let parts = s.parts.map { "\($0.label.isEmpty ? "" : $0.label + "=")\($0.percent)%\($0.charging == true ? "⚡︎" : "")" }
            DebugHooks.log("‹akku› \(s.source.rawValue) \(s.key.name) [\(s.key.model)] \(parts.joined(separator: " ")) (\(s.precision))")
        }
        var perSource = samples[s.key] ?? [:]
        if let old = perSource[s.source], old.observedAt > s.observedAt { return }   // nichts Älteres übernehmen
        var sample = s
        // AirPods-Signale enthalten nicht immer alle Teile (z. B. Etui zu) →
        // fehlende Teile übernehmen, aber nur solange SIE SELBST frisch sind
        // (eigener Zeitstempel pro Teil, ohne alten Lade-Blitz).
        if s.source == .proximity {
            var seen = slotSeen[s.key] ?? [:]
            for p in s.parts { seen[p.slot] = s.observedAt }
            if let old = perSource[.proximity] {
                let have = Set(s.parts.map(\.slot))
                let carried = old.parts.filter { p in
                    !have.contains(p.slot) &&
                    s.observedAt.timeIntervalSince(seen[p.slot] ?? old.observedAt) < BatterySource.proximity.ttl
                }.map { BatteryPart(slot: $0.slot, percent: $0.percent, charging: nil) }
                for slot in Set(old.parts.map(\.slot)).subtracting(have).subtracting(carried.map(\.slot)) {
                    seen.removeValue(forKey: slot)
                }
                sample = BatterySample(key: s.key, parts: (s.parts + carried).sorted { $0.slot.order < $1.slot.order },
                                       precision: s.precision, source: s.source, observedAt: s.observedAt)
            }
            slotSeen[s.key] = seen
        }
        perSource[s.source] = sample
        samples[s.key] = perSource
        rebuild()
        scheduleSave()
    }

    func ingest(_ list: [BatterySample]) { list.forEach(ingest) }

    /// Regelmässig aufrufen, damit „frisch/veraltet“ und das 14-Tage-Aufräumen
    /// stimmen. Das angezeigte Alter rechnet die Ansicht selbst (TimelineView).
    func refreshAges() { rebuild() }

    // MARK: Auswahl

    private func best(_ perSource: [BatterySource: BatterySample], now: Date) -> (BatterySample, Bool)? {
        let all = Array(perSource.values)
        guard !all.isEmpty else { return nil }
        let fresh = all.filter { now.timeIntervalSince($0.observedAt) < $0.source.ttl }
        if let f = fresh.max(by: { ($0.precision, $0.observedAt) < ($1.precision, $1.observedAt) }) {
            return (f, false)
        }
        guard let newest = all.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        return (newest, true)
    }

    private func rebuild() {
        let now = Date()
        samples = samples.compactMapValues { per in
            let kept = per.filter { now.timeIntervalSince($0.value.observedAt) < retention }
            return kept.isEmpty ? nil : kept
        }
        // Gleiche Namen (zwei „iPhone von Aralim“) → Modell anhängen.
        var nameCount: [String: Int] = [:]
        for k in samples.keys { nameCount[k.name, default: 0] += 1 }

        var list: [Entry] = []
        for (key, per) in samples {
            guard let (s, stale) = best(per, now: now) else { continue }
            let name = (nameCount[key.name] ?? 0) > 1
                ? "\(key.name) · \(DeviceNames.marketing(key.model))" : key.name
            list.append(Entry(key: key, displayName: name,
                              symbol: DeviceNames.symbol(for: key.kind, model: key.model),
                              parts: s.parts, precision: s.precision, source: s.source,
                              observedAt: s.observedAt, stale: stale))
        }
        list.sort {
            if $0.stale != $1.stale { return !$0.stale }
            if $0.key.kind != $1.key.kind { return $0.key.kind.order < $1.key.kind.order }
            return $0.displayName < $1.displayName
        }
        if list != entries { entries = list }
    }

    // MARK: Speichern

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        guard persistenceEnabled else { return }
        let flat = samples.values.flatMap { $0.values }
        if let data = try? JSONEncoder().encode(flat) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let flat = try? JSONDecoder().decode([BatterySample].self, from: data) else { return }
        for s in flat { samples[s.key, default: [:]][s.source] = s }
    }
}

private extension BatteryPart.Slot {
    var order: Int {
        switch self {
        case .main: return 0
        case .left: return 1
        case .right: return 2
        case .chargingCase: return 3
        }
    }
}

private extension DeviceKind {
    var order: Int {
        switch self {
        case .iPhone: return 0
        case .iPad: return 1
        case .watch: return 2
        case .airPods: return 3
        case .beats: return 4
        case .accessory: return 5
        }
    }
}

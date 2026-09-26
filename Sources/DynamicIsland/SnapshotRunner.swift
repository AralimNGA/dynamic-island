import AppKit
import SwiftUI

/// Test-/Entwickler-Hooks über Umgebungsvariablen (nur für die Verifikation):
/// - ISLAND_SNAPSHOT=<ordner>   alle Zustände als PNG rendern, dann beenden
/// - ISLAND_FORCE_EXPAND=1      nach dem Start offen (ISLAND_TAB=<rawValue> wählt den Tab,
///                              ISLAND_HOLD_OPEN=1 verhindert das Zuklappen)
/// - ISLAND_OPEN_SETTINGS=1     Einstellungsfenster öffnen
/// - ISLAND_AI_TEST=<frage>     Frage an den Assistenten, Verlauf auf stderr (ISLAND_AI_CONFIRM=allow|deny)
enum DebugHooks {
    static func run(env: [String: String], services s: IslandServices, controller: IslandController) {
        if let dir = env["ISLAND_SNAPSHOT"] {
            SnapshotRunner(dir: dir, services: s, view: controller.contentView).run()
        }
        if env["ISLAND_SELFTEST"] == "1" {
            log("‹selftest› AirPods-Decoder: \(ProximityPairingScanner.selfTest() ? "OK" : "FEHLER")")
            NSApp.terminate(nil)
        }
        if env["ISLAND_FORCE_EXPAND"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                s.state.open(env["ISLAND_TAB"].flatMap(ExpandedTab.init(rawValue:)))
            }
        }
        if env["ISLAND_HOLD_OPEN"] == "1" { s.state.holdOpen = { true } }
        if env["ISLAND_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                (NSApp.delegate as? AppDelegate)?.openSettings()
            }
        }
        if let q = env["ISLAND_AI_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { s.claude.ask(q) }
            if let mode = env["ISLAND_AI_CONFIRM"] {
                let t = Timer(timeInterval: 0.4, repeats: true) { _ in
                    guard s.claude.pendingAction != nil else { return }
                    log("‹ai› confirm-card -> \(mode)")
                    if mode == "allow" { s.claude.allowPending() } else { s.claude.denyPending() }
                }
                RunLoop.main.add(t, forMode: .common)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14.0) {
                for t in s.claude.turns {
                    log("‹ai› [\(t.role)] \(t.text)")
                    for b in t.blocks {
                        if case let .toolUse(_, name, input) = b { log("‹ai›   →tool_use \(name) \(input)") }
                        if case let .toolResult(_, content, isErr) = b {
                            log("‹ai›   ←result(err=\(isErr)) \(content.prefix(90))")
                        }
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}

/// Test-only: drives the island through several states and renders each to a PNG
/// in-process (no Screen Recording permission needed), then quits.
final class SnapshotRunner {
    private let dir: String
    private let s: IslandServices
    private let view: NSView

    init(dir: String, services: IslandServices, view: NSView) {
        self.dir = dir
        self.s = services
        self.view = view
    }

    func run() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let state = s.state, media = s.media

        let fakeTrack = NowPlaying(app: "Spotify", title: "Blinding Lights",
                                   artist: "The Weeknd", album: "After Hours",
                                   isPlaying: true, duration: 200, position: 82, artworkURL: "",
                                   shuffling: true, repeating: false)

        func reset() {
            state.pinnedOpen = false
            state.hovering = false
            state.hoverIntent = false
            state.banner = nil
            state.transientActivity = .idle
            state.privacy = .init()
            media.showMediaPeek = false
        }

        let steps: [(String, () -> Void)] = [
            ("01_hidden", { reset(); media.info = NowPlaying() }),
            ("02_lip", { reset(); state.hoverIntent = true }),
            ("03_media_peek", {
                reset()
                media.info = fakeTrack; media.accent = .pink; media.showMediaPeek = true
            }),
            ("04_volume_hud", { reset(); state.transientActivity = .volume(level: 0.62, muted: false, symbol: "") }),
            ("05_brightness_hud", { reset(); state.transientActivity = .brightness(level: 0.35) }),
            ("06_charging", { reset(); state.transientActivity = .charging(percent: 82, full: false) }),
            ("07_low_battery", { reset(); state.transientActivity = .lowBattery(percent: 9) }),
            ("08_privacy", { reset(); state.privacy = .init(camera: true, mic: true) }),
            ("09_unlocked", { reset(); state.transientActivity = .unlocked }),
            ("10_banner_track", { reset(); media.info = fakeTrack; state.banner = .track }),
            ("11_banner_airpods", {
                reset()
                state.banner = .device(name: "AirPods Pro von Aralim", symbol: "airpodspro",
                                       readings: [.init(label: "L", percent: 82), .init(label: "R", percent: 78),
                                                  .init(label: "Case", percent: 95)])
            }),
            ("12_banner_timer", {
                reset()
                state.banner = .message(symbol: "timer", title: "Timer abgelaufen", subtitle: "Zeit ist um", tint: .orange)
            }),
            ("13_home", {
                reset()
                media.info = fakeTrack; media.accent = .pink
                self.s.timer.startCountdown(seconds: 305)
                state.selectedTab = .home
                state.pinnedOpen = true
            }),
            ("14_home_empty", {
                self.s.timer.stop()
                media.info = NowPlaying()
                state.selectedTab = .home
            }),
            ("15_music", { media.info = fakeTrack; media.accent = .pink; state.selectedTab = .nowPlaying }),
            ("16_timer", { self.s.timer.startCountdown(seconds: 125); state.selectedTab = .timer }),
            ("17_shelf", { self.s.timer.stop(); state.selectedTab = .shelf }),
            ("18_claude", { state.selectedTab = .claude }),
            ("19_devices", {
                let store = self.s.remoteBattery.store
                store.persistenceEnabled = false
                let now = Date()
                store.ingest([
                    BatterySample(key: .init(kind: .iPhone, model: "iPhone17,1", name: "iPhone von Aralim"),
                                  parts: [.init(slot: .main, percent: 75, charging: nil)],
                                  precision: .bucket4, source: .hotspot, observedAt: now),
                    BatterySample(key: .init(kind: .iPhone, model: "iPhone19,7", name: "iPhone von Aralim"),
                                  parts: [.init(slot: .main, percent: 50, charging: nil)],
                                  precision: .bucket4, source: .hotspot, observedAt: now.addingTimeInterval(-240)),
                    BatterySample(key: .init(kind: .iPad, model: "iPad17,4", name: "iPad von Aralim (2)"),
                                  parts: [.init(slot: .main, percent: 100, charging: nil)],
                                  precision: .bucket4, source: .hotspot, observedAt: now),
                    BatterySample(key: .init(kind: .airPods, model: "0x2027", name: "AirPods Pro von Aralim"),
                                  parts: [.init(slot: .left, percent: 80, charging: false),
                                          .init(slot: .right, percent: 70, charging: false),
                                          .init(slot: .chargingCase, percent: 40, charging: true)],
                                  precision: .step10, source: .proximity, observedAt: now),
                ])
                state.selectedTab = .devices
            }),
        ]

        var delay = 0.6
        for (name, setup) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { setup() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.0) { MainActor.assumeIsolated { self.capture(named: name) } }
            delay += 1.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) { NSApp.terminate(nil) }
    }

    @MainActor private func capture(named name: String) {
        // SwiftUI direkt rendern (mit Transparenz) – cacheDisplay liefert bei
        // Layer-Views schwarz statt durchsichtig.
        let size = view.bounds.size
        let renderer = ImageRenderer(content: IslandRootView(services: s, forSnapshot: true).frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let island = renderer.nsImage else { return }

        // Hintergrund wie eine helle Menüleiste mit schwarzer Notch – so sieht man,
        // was wirklich über die Notch hinaus gezeichnet wird.
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let m = s.state.metrics
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: (size.width - m.notchWidth) / 2, y: size.height - m.notchHeight,
                                         width: m.notchWidth, height: m.notchHeight + 10),
                     xRadius: 9, yRadius: 9).fill()
        island.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        try? png.write(to: URL(fileURLWithPath: path))
        DebugHooks.log("snapshot: \(path)")
    }
}

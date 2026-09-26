import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: IslandServices!
    private var controller: IslandController?
    private var router: IslandCommandRouter?
    private var systemControl: SystemControl?
    private var statusItem: NSStatusItem?
    private var keyRetryTimer: Timer?
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        handleSIGTERM()
        let env = ProcessInfo.processInfo.environment
        if env["ISLAND_DISCOVERABLE"] == "1" { NSApp.setActivationPolicy(.regular) }

        let metrics = NotchMetrics.current()
        FileHandle.standardError.write(("DynamicIsland: notch \(Int(metrics.notchWidth))×\(Int(metrics.notchHeight)) pt, "
            + "center x=\(Int(metrics.notchCenterX)), topY=\(Int(metrics.screenTopY)), hasNotch=\(metrics.hasNotch)\n")
            .data(using: .utf8)!)

        let s = IslandServices(metrics: metrics)
        services = s
        let controller = IslandController(services: s)
        self.controller = controller

        let router = IslandCommandRouter(state: s.state, media: s.media, timer: s.timer,
                                         todo: s.todo, settings: AppSettings.shared)
        self.router = router
        s.claude.onCommand = { [weak router] command in router?.handle(command) }

        // The assistant's tool-execution layer (Island + Mac control).
        let systemControl = SystemControl(router: router, media: s.media)
        self.systemControl = systemControl
        s.claude.systemControl = systemControl
        s.state.holdOpen = { [weak s] in s?.claude.pendingAction != nil }

        let snapshotMode = env["ISLAND_SNAPSHOT"] != nil
        wireActivities()
        if !snapshotMode {
            s.media.start()          // poller would overwrite injected demo state
            startSystemEvents()
        }
        s.battery.start()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            forName: .openIslandSettings, object: nil, queue: .main) { [weak self] _ in self?.openSettings() }

        DebugHooks.run(env: env, services: s, controller: controller)
    }

    /// SIGTERM (z. B. `pkill`, Abmelden) sauber behandeln, damit der perl-Stream
    /// des Now-Playing-Adapters nicht verwaist. Nach Absturz/SIGKILL räumt der
    /// nächste Start alte Streams auf (MediaRemoteSource.killOrphanStreams).
    private var sigtermSource: DispatchSourceSignal?

    private func handleSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigtermSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.media.shutdown()
        PrivateSpace.shared.destroy()
    }

    // MARK: - Live-Aktivitäten

    private func wireActivities() {
        let s = services!
        let settings = AppSettings.shared

        s.battery.onPlugChange = { [weak s] plugged in
            guard let s else { return }
            if plugged {
                s.state.flashActivity(.charging(percent: s.battery.percent, full: s.battery.percent >= 100), duration: 4.0)
            } else {
                s.state.flashActivity(.custom(symbol: "powerplug", text: "Netz getrennt", tint: .orange), duration: 2.5)
            }
        }
        s.battery.onPercentChange = { [weak s] old, new in
            guard let s, settings.batteryAlerts else { return }
            if !s.battery.isPluggedIn, let level = [20, 10, 5].first(where: { old > $0 && new <= $0 }) {
                s.state.flashActivity(.lowBattery(percent: new), duration: 5.0)
                if level <= 10 {
                    s.state.showBanner(.message(symbol: "battery.25percent", title: "Akku fast leer",
                                                subtitle: "Noch \(new) % – bitte Netzteil anschliessen", tint: .red), duration: 5)
                }
            } else if s.battery.isPluggedIn, old < 100, new >= 100 {
                s.state.flashActivity(.charging(percent: 100, full: true), duration: 3.5)
            }
        }

        s.timer.onFinished = { [weak s] in
            NSSound(named: "Glass")?.play()
            s?.state.showBanner(.message(symbol: "timer", title: "Timer abgelaufen",
                                         subtitle: "Zeit ist um", tint: .orange), duration: 6)
        }

        s.media.onTrackChanged = { [weak self, weak s] in
            guard let self, let s, settings.trackBanner else { return }
            // Nicht beim Start (erste Erkennung) und nicht für Browser-Videos.
            guard Date().timeIntervalSince(self.launchedAt) > 4,
                  s.media.isPlaying, !s.media.info.isBrowser else { return }
            s.state.showBanner(.track, duration: 3.2)
        }
    }

    private func startSystemEvents() {
        let s = services!
        let settings = AppSettings.shared

        // Lautstärke (auch ohne Bedienungshilfen – dann zusätzlich zum System-HUD).
        s.audio.onVolumeChange = { [weak s] level, muted in
            guard let s, settings.volumeHUD else { return }
            s.state.flashActivity(.volume(level: level, muted: muted, symbol: ""), duration: 1.6)
        }
        s.audio.onOutputChange = { [weak s] out in
            guard let s, settings.deviceBanner else { return }
            let symbol = AudioMonitor.symbol(forDevice: out.name, bluetooth: out.isBluetooth)
            if out.isBluetooth {
                let cached = s.deviceBattery.devices.first { $0.name == out.name }?.readings ?? []
                s.state.showBanner(.device(name: out.name, symbol: symbol, readings: cached), duration: 4.5)
                s.deviceBattery.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if let d = s.deviceBattery.devices.first(where: { $0.name == out.name && $0.connected }) {
                        s.state.updateBanner(.device(name: out.name, symbol: symbol, readings: d.readings))
                    }
                }
            } else {
                s.state.flashActivity(.custom(symbol: symbol, text: Self.shortName(out.name), tint: .white), duration: 2.2)
            }
        }
        s.audio.start()

        // Kamera/Mikrofon in Benutzung (eigene Nutzung ausgenommen).
        s.privacy.ownCameraInUse = { [weak s] in s?.camera.session.isRunning ?? false }
        s.privacy.ownMicInUse = { [weak s] in s?.recorder.isRecording ?? false }
        s.privacy.onChange = { [weak s] usage in
            withAnimation(.islandOpen) { s?.state.privacy = usage }
        }
        s.privacy.start()

        // Akkus der anderen Apple-Geräte (Hotspot sofort, Bluetooth erst nach Freigabe).
        s.remoteBattery.start()

        s.lock.onUnlock = { [weak s] in
            guard let s, settings.unlockAnimation else { return }
            s.state.flashActivity(.unlocked, duration: 1.6)
        }
        s.lock.start()

        // Lautstärke-/Helligkeitstasten – braucht Bedienungshilfen.
        s.keys.onMediaKey = { [weak s] key, fine in
            guard let s, settings.replaceSystemHUD else { return false }
            return Self.handleMediaKey(key, fine: fine, services: s)
        }
        startKeyInterceptor(prompt: settings.replaceSystemHUD)
    }

    /// Startet den Tasten-Tap. Fehlt die Freigabe, einmalig danach fragen und
    /// im Hintergrund weiterprobieren – sobald erlaubt, läuft es ohne Neustart.
    func startKeyInterceptor(prompt: Bool) {
        let s = services!
        if s.keys.start() { return }
        let asked = "askedAccessibility.v2"
        if prompt, !UserDefaults.standard.bool(forKey: asked) {
            UserDefaults.standard.set(true, forKey: asked)
            KeyInterceptor.requestTrust()
        }
        guard keyRetryTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            if self?.services.keys.start() == true {
                timer.invalidate()
                self?.keyRetryTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        keyRetryTimer = t
    }

    private static func handleMediaKey(_ key: KeyInterceptor.MediaKey, fine: Bool, services s: IslandServices) -> Bool {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .volumeUp, .volumeDown:
            guard s.audio.canSetVolume else { return false }
            let cur = (s.audio.volume / step).rounded() * step
            let next = min(1, max(0, cur + (key == .volumeUp ? step : -step)))
            s.audio.setVolume(next)
            if next > 0, s.audio.isMuted { s.audio.setMuted(false) }
            s.state.flashActivity(.volume(level: next, muted: false, symbol: ""), duration: 1.6)
            return true
        case .mute:
            guard s.audio.canSetVolume else { return false }
            let muted = !s.audio.isMuted
            s.audio.setMuted(muted)
            s.state.flashActivity(.volume(level: s.audio.volume, muted: muted, symbol: ""), duration: 1.6)
            return true
        case .brightnessUp, .brightnessDown:
            guard let cur = DisplayBrightness.get() else { return false }
            let next = min(1, max(0, (cur / step).rounded() * step + (key == .brightnessUp ? step : -step)))
            DisplayBrightness.set(next)
            s.state.flashActivity(.brightness(level: next), duration: 1.6)
            return true
        }
    }

    private static func shortName(_ name: String) -> String {
        name.count > 18 ? String(name.prefix(17)) + "…" : name
    }

    @objc private func screenChanged() {
        controller?.refreshMetrics()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Dynamic Island")
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Dynamic Island", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Island öffnen", action: #selector(openIsland), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Beim Anmelden starten",
                                   action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openIsland() {
        services.state.open()
    }

    func applyCaptureSetting() {
        controller?.applyCaptureSetting()
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show(services: services, app: self)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = IslandState()
    private let media = MediaController()
    private let battery = BatteryMonitor()
    private let timer = TimerModel()
    private let shelf = ShelfModel()
    private let calendar = CalendarService()
    private let claude = ClaudeService()
    private let camera = CameraController()
    private let recorder = AudioRecorder()
    private let todo = TodoModel()
    private let weather = WeatherService()
    private let stocks = StockService()
    private let deviceBattery = DeviceBatteryService()

    private var controller: IslandController?
    private var router: IslandCommandRouter?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let env = ProcessInfo.processInfo.environment
        // Test hooks: make the agent discoverable / force a state for verification.
        if env["ISLAND_DISCOVERABLE"] == "1" {
            NSApp.setActivationPolicy(.regular)
        }

        let metrics = NotchMetrics.current()
        let log = "DynamicIsland: notch \(Int(metrics.notchWidth))×\(Int(metrics.notchHeight)) pt, "
            + "center x=\(Int(metrics.notchCenterX)), topY=\(Int(metrics.screenTopY)), "
            + "hasNotch=\(metrics.hasNotch)\n"
        FileHandle.standardError.write(log.data(using: .utf8)!)
        controller = IslandController(state: state, media: media, battery: battery,
                                      timer: timer, shelf: shelf, calendar: calendar,
                                      claude: claude, camera: camera, recorder: recorder,
                                      todo: todo, weather: weather, stocks: stocks,
                                      deviceBattery: deviceBattery, metrics: metrics)

        let router = IslandCommandRouter(state: state, media: media, timer: timer,
                                         todo: todo, settings: AppSettings.shared)
        self.router = router
        claude.onCommand = { [weak router] command in router?.handle(command) }

        wireCallbacks()
        if env["ISLAND_SNAPSHOT"] == nil { media.start() }   // poller would overwrite injected demo state
        battery.start()
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        NotificationCenter.default.addObserver(
            forName: .openIslandSettings, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            SettingsWindowController.shared.show(claude: self.claude, media: self.media)
        }

        if let path = env["ISLAND_LIVE_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let controller = self.controller else { return }
                self.state.pinnedOpen = true
                self.state.selectedTab = .nowPlaying
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let v = controller.contentView
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        let img = NSImage(size: v.bounds.size)
                        img.lockFocus()
                        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
                        NSRect(origin: .zero, size: v.bounds.size).fill()
                        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
                        img.unlockFocus()
                        if let tiff = img.tiffRepresentation, let bm = NSBitmapImageRep(data: tiff),
                           let png = bm.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }

        if env["ISLAND_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openSettings() }
        }

        if let path = env["ISLAND_DEVICE_SHOT"] {
            self.state.pinnedOpen = true
            self.state.selectedTab = .devices
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.deviceBattery.devices = [
                    .init(name: "AirPods Pro", symbol: "airpodspro",
                          readings: [.init(label: "L", percent: 82), .init(label: "R", percent: 78), .init(label: "Case", percent: 95)],
                          connected: true, lastSeen: Date()),
                    .init(name: "Magic Mouse", symbol: "magicmouse",
                          readings: [.init(label: "", percent: 24)],
                          connected: false, lastSeen: Date().addingTimeInterval(-5400)),
                ]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureContainer(to: path)
                    NSApp.terminate(nil)
                }
            }
        }

        if let dir = env["ISLAND_INFO_SHOTS"] {
            let steps: [(ExpandedTab, String, Double)] = [
                (.weather, "weather", 2.5), (.stocks, "stocks", 2.5), (.devices, "devices", 2.5),
            ]
            var t = 1.5
            self.state.pinnedOpen = true
            for (tab, name, wait) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.state.selectedTab = tab }
                DispatchQueue.main.asyncAfter(deadline: .now() + t + wait) { [weak self] in
                    self?.captureContainer(to: "\(dir)/\(name).png")
                }
                t += wait + 0.3
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }

        if env["ISLAND_FORCE_EXPAND"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.state.pinnedOpen = true
            }
        }

        if let dir = env["ISLAND_SNAPSHOT"], let controller {
            SnapshotRunner(dir: dir, state: state, media: media, timer: timer,
                           shelf: shelf, todo: todo, view: controller.contentView).run()
        }

        if let path = env["ISLAND_SETTINGS_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                SettingsWindowController.shared.show(claude: self.claude, media: self.media)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if let win = NSApp.windows.first(where: { $0.title.contains("Einstellungen") }),
                       let cv = win.contentView,
                       let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                        cv.cacheDisplay(in: cv.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: path))
                            FileHandle.standardError.write("settings shot: \(path)\n".data(using: .utf8)!)
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func wireCallbacks() {
        battery.onPlugChange = { [weak self] plugged in
            guard let self else { return }
            if plugged {
                let full = self.battery.percent >= 100
                self.state.flashActivity(.charging(percent: self.battery.percent, full: full), duration: 4.0)
            } else {
                self.state.flashActivity(.custom(symbol: "powerplug", text: "Netz getrennt", tint: .orange), duration: 2.5)
            }
        }
        timer.onFinished = { [weak self] in
            NSSound.beep()
            self?.state.flashActivity(.custom(symbol: "timer", text: "Fertig", tint: .green), duration: 5.0)
        }
    }

    @objc private func screenChanged() {
        controller?.position()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                 accessibilityDescription: "Dynamic Island") {
                button.image = img
            } else {
                button.title = "◗"
            }
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Dynamic Island", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Beim Anmelden starten",
                                   action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
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

    @objc private func openSettings() {
        SettingsWindowController.shared.show(claude: claude, media: media)
    }

    func captureContainer(to path: String) {
        guard let v = controller?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let bm = NSBitmapImageRep(data: tiff),
           let png = bm.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

import SwiftUI
import AppKit
import ServiceManagement
import Combine

/// Native, Apple-style preferences window (segmented toolbar tabs).
struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var claude: ClaudeService
    @ObservedObject var media: MediaController
    let services: IslandServices
    weak var app: AppDelegate?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("Allgemein", systemImage: "gearshape") }
            activitiesTab.tabItem { Label("Aktivitäten", systemImage: "capsule.fill") }
            appearanceTab.tabItem { Label("Darstellung", systemImage: "paintpalette") }
            tabsTab.tabItem { Label("Tabs", systemImage: "square.grid.2x2") }
            musicTab.tabItem { Label("Musik", systemImage: "music.note.list") }
            assistantTab.tabItem { Label("Assistent", systemImage: "sparkles") }
        }
        .frame(width: 540, height: 520)
    }

    // MARK: Assistant

    @State private var keyInput = ""

    private var assistantTab: some View {
        Form {
            Picker("Anbieter", selection: $settings.aiProvider) {
                ForEach(AppSettings.AIProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            if settings.aiProvider == .anthropic {
                Section {
                    HStack {
                        SecureField("API-Schlüssel (sk-ant-…)", text: $keyInput)
                        Button("Speichern") {
                            claude.saveKey(keyInput); keyInput = ""
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Aus Zwischenablage einfügen") { claude.pasteKeyFromClipboard() }
                    HStack(spacing: 6) {
                        Image(systemName: claude.hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .foregroundStyle(claude.hasKey ? .green : .orange)
                        Text(claude.hasKey ? "Schlüssel hinterlegt" : "Noch kein Schlüssel")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Picker("Modell", selection: $settings.anthropicModel) {
                        ForEach(AppSettings.anthropicModels, id: \.id) { Text($0.label).tag($0.id) }
                    }
                } header: {
                    Text("Anthropic")
                } footer: {
                    Text("Kostenpflichtig (API-Guthaben). Schlüssel auf console.anthropic.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Server-URL", text: $settings.lmStudioURL)
                    TextField("Modell", text: $settings.lmStudioModel)
                } header: {
                    Text("LM Studio")
                } footer: {
                    Text("Kostenlos & lokal. In LM Studio den Server starten (Developer ▸ Start Server). Standard: http://localhost:1234")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    // MARK: Music

    @State private var newPlaylistName = ""
    @State private var newPlaylistURI = ""

    private var musicTab: some View {
        Form {
            Section {
                Toggle("Systemweit (jede App: Podcasts, Browser, VLC …)", isOn: $settings.systemNowPlaying)
                    .onChange(of: settings.systemNowPlaying) { _, on in media.setSystemWide(on) }
                HStack(spacing: 6) {
                    Image(systemName: media.systemWide ? "checkmark.seal.fill" : "applescript")
                        .foregroundStyle(media.systemWide ? .green : .secondary)
                    Text(media.systemWide ? "MediaRemote aktiv" : "AppleScript (Spotify, Musik, Browser)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } header: {
                Text("Quelle")
            } footer: {
                Text("Systemweit nutzt den quelloffenen mediaremote-adapter (Vendor/). Falls macOS den Zugriff sperrt, fällt die App automatisch auf AppleScript zurück.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if settings.playlists.isEmpty {
                    Text("Noch keine Playlists").foregroundStyle(.secondary)
                }
                ForEach(settings.playlists) { pl in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pl.name)
                            Text(pl.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.playlists.removeAll { $0.id == pl.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Spotify-Playlists")
            } footer: {
                Text("In Spotify: Rechtsklick auf eine Playlist → Teilen → Link bzw. Spotify-URI kopieren. Wechseln dann im Musik-Tab der Island.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hinzufügen") {
                TextField("Name", text: $newPlaylistName)
                TextField("Link oder URI", text: $newPlaylistURI)
                Button("Hinzufügen") { addPlaylist() }
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newPlaylistURI.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private func addPlaylist() {
        let uri = normalizeSpotify(newPlaylistURI)
        settings.playlists.append(.init(name: newPlaylistName.trimmingCharacters(in: .whitespaces), uri: uri))
        newPlaylistName = ""; newPlaylistURI = ""
    }

    private func normalizeSpotify(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("spotify:") { return t }
        if let url = URL(string: t), (url.host ?? "").contains("open.spotify.com") {
            let comps = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            if comps.count >= 2 { return "spotify:\(comps[comps.count - 2]):\(comps[comps.count - 1])" }
        }
        return t
    }

    // MARK: Appearance

    private var appearanceTab: some View {
        Form {
            Section("Akzentfarbe") {
                HStack(spacing: 12) {
                    ForEach(AppSettings.accentOptions, id: \.name) { option in
                        Circle()
                            .fill(option.color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().strokeBorder(.primary.opacity(settings.accentName == option.name ? 0.9 : 0), lineWidth: 2)
                            )
                            .onTapGesture { settings.accentName = option.name }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack {
                    Text("Wenig")
                    Slider(value: $settings.notchFlare, in: 0...16, step: 1)
                    Text("Viel")
                }
                .font(.caption)
            } header: {
                Text("Obere Eck-Rundung")
            } footer: {
                Text("Wie stark die oberen Ecken nach außen zum Bildschirmrand auslaufen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    // MARK: Tabs

    private var tabsTab: some View {
        Form {
            Section {
                ForEach(ExpandedTab.allCases) { tab in
                    Toggle(isOn: Binding(
                        get: { settings.isEnabled(tab) },
                        set: { settings.setEnabled(tab, $0) }
                    )) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                }
            } header: {
                Text("Sichtbare Tabs")
            } footer: {
                Text("Wähle, welche Tabs in der aufgeklappten Island erscheinen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    // MARK: Aktivitäten

    @State private var axTrusted = KeyInterceptor.isTrusted
    private let axTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var activitiesTab: some View {
        Form {
            Section {
                Toggle("Neuer Titel als Mitteilung", isOn: $settings.trackBanner)
                Toggle("Kopfhörer / Ausgabegerät verbunden", isOn: $settings.deviceBanner)
                Toggle("Kamera- und Mikrofon-Anzeige", isOn: $settings.showPrivacyIndicator)
                Toggle("Entsperren-Animation", isOn: $settings.unlockAnimation)
                Toggle("Akku-Warnungen (20 %, 10 %, 5 %, voll)", isOn: $settings.batteryAlerts)
            } header: {
                Text("Live-Aktivitäten")
            } footer: {
                Text("Wie auf dem iPhone: Kleine Anzeigen links und rechts der Kamera, Mitteilungen wachsen kurz unter der Notch heraus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("iPhone & iPad über Instant Hotspot (grob, ohne Einrichtung)", isOn: $settings.remoteBatteryHotspot)
                    .onChange(of: settings.remoteBatteryHotspot) { services.remoteBattery.applySettings() }
                Toggle("AirPods in der Nähe über Bluetooth", isOn: $settings.remoteBatteryBLE)
                    .onChange(of: settings.remoteBatteryBLE) { _, on in
                        if on { services.remoteBattery.enableBluetooth() } else { services.remoteBattery.applySettings() }
                    }
                Toggle("Genaue Werte über Kabel-Kopplung (iPhone, iPad, Apple Watch)", isOn: $settings.remoteBatteryLockdown)
                    .onChange(of: settings.remoteBatteryLockdown) { services.remoteBattery.applySettings() }
            } header: {
                Text("Akku anderer Geräte")
            } footer: {
                Text("Werte kommen direkt von Geräten in der Nähe (Bluetooth/WLAN), nicht aus iCloud. Für genaue Prozente und die Apple Watch: iPhone bzw. iPad einmal per Kabel an diesen Mac anschliessen, „Vertrauen“ tippen und im Finder „Im WLAN anzeigen“ aktivieren.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Lautstärke-Anzeige in der Island", isOn: $settings.volumeHUD)
                Toggle("System-HUD ersetzen (Lautstärke + Helligkeit)", isOn: $settings.replaceSystemHUD)
                HStack(spacing: 6) {
                    Image(systemName: axTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Text(axTrusted ? "Bedienungshilfen erlaubt" : "Bedienungshilfen noch nicht erlaubt")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !axTrusted {
                        Button("Erlauben …") {
                            KeyInterceptor.requestTrust()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                            app?.startKeyInterceptor(prompt: false)
                        }
                    }
                }
                .font(.callout)
            } header: {
                Text("Lautstärke und Helligkeit")
            } footer: {
                Text("Ohne Freigabe zeigt die Island die Lautstärke zusätzlich zum System-HUD. Mit „Bedienungshilfen“ ersetzt sie es ganz (auch Helligkeit, ⇧⌥ für feine Schritte). Nach jedem Neubau muss die Freigabe erneut gesetzt werden (Ad-hoc-Signatur).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onReceive(axTimer) { _ in axTrusted = KeyInterceptor.isTrusted }
    }

    // MARK: General

    @State private var launchAtLogin = SettingsView.loginEnabled()

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Beim Anmelden starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in setLogin(newValue) }
            }
            Section {
                Picker("Öffnen", selection: $settings.openOnHover) {
                    Text("Beim Darüberfahren").tag(true)
                    Text("Per Klick").tag(false)
                }
                .pickerStyle(.segmented)
                if settings.openOnHover {
                    LabeledContent("Verzögerung") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0...0.6, step: 0.05)
                            Text("\(Int(settings.hoverDelay * 1000)) ms")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Toggle("Haptisches Feedback (Trackpad)", isOn: $settings.haptics)
                Toggle("In Screenshots und Aufnahmen ausblenden", isOn: $settings.hideInScreenshots)
                    .onChange(of: settings.hideInScreenshots) { app?.applyCaptureSetting() }
            } header: {
                Text("Verhalten")
            } footer: {
                Text("Gesten auf der Island: zwei Finger nach unten ziehen öffnet, links/rechts wischen wechselt Tab bzw. Titel. Klick auf eine Aktivität öffnet den passenden Tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Symbole, z.B. AAPL, MSFT, NVDA", text: stockSymbolsBinding)
            } header: {
                Text("Aktien-Tab")
            } footer: {
                Text("Kommagetrennte Börsenkürzel (Yahoo-Finance-Symbole).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Berechtigungen") {
                Button("Medien-Zugriff anfragen (Spotify / Music)") {
                    media.requestAutomationPermission()
                }
                Button("Automations-Einstellungen öffnen") {
                    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
            }
            Section {
                LabeledContent("Version", value: "2.0")
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private var stockSymbolsBinding: Binding<String> {
        Binding(
            get: { settings.stockSymbols.joined(separator: ", ") },
            set: { newValue in
                settings.stockSymbols = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    private static func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { NSSound.beep() }
    }
}

/// Owns the single Settings window. Switches the (accessory) app to a regular
/// app while the window is open, so it reliably comes to the front and can be
/// focused — then switches back to accessory when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(services: IslandServices, app: AppDelegate?) {
        NSApp.setActivationPolicy(.regular)

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(claude: services.claude, media: services.media,
                                                                     services: services, app: app))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Dynamic Island – Einstellungen"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only agent.
        NSApp.setActivationPolicy(.accessory)
    }
}

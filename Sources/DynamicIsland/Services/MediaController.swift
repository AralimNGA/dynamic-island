import AppKit
import SwiftUI
import Combine

struct NowPlaying: Equatable {
    var app: String = ""          // "Spotify" | "Music" | a browser name
    var title: String = ""
    var artist: String = ""
    var album: String = ""        // for browser: the site name (YouTube, Netflix…)
    var isPlaying: Bool = false
    var duration: Double = 0      // seconds
    var position: Double = 0      // seconds
    var artworkURL: String = ""
    var shuffling = false
    var repeating = false
    var trackURI = ""
    var isBrowser = false         // a video playing in a web browser
    var canSeek = true            // false for a browser video without JS access (display-only)

    var hasTrack: Bool { !title.isEmpty }
    var trackKey: String { app + "|" + title + "|" + artist }
}

/// Now Playing der Island. Hauptquelle ist MediaRemote (systemweit, jede App,
/// über `MediaRemoteSource`). Ist das nicht verfügbar, liest die Klasse Spotify,
/// Apple Music und Browser-Videos per AppleScript. Spotify-Extras (Shuffle,
/// Wiederholen, Playlists) laufen immer über AppleScript.
final class MediaController: ObservableObject {
    enum RepeatMode: String { case off, all, one }

    @Published var info = NowPlaying()
    @Published var artwork: NSImage?
    @Published var accent: Color = Color(white: 0.4)
    @Published var repeatMode: RepeatMode = .off
    /// Whether the compact now-playing peek should be visible. Stays on while
    /// playing; after pausing it lingers ~5 s, then hides (like the iPhone).
    @Published var showMediaPeek = false

    private var lockedURI = ""   // for app-side "repeat one" on Spotify
    private var pauseHideWork: DispatchWorkItem?
    private var prevPlaying = false
    private var prevHasTrack = false

    /// Fired when the track changes (used to trigger a peek).
    var onTrackChanged: (() -> Void)?

    var isPlaying: Bool { info.isPlaying && info.hasTrack }
    var hasTrack: Bool { info.hasTrack }

    /// true = Daten kommen systemweit aus MediaRemote, sonst AppleScript-Polling.
    @Published private(set) var systemWide = false

    private let remote = MediaRemoteSource()
    private var remoteSnap: MediaRemoteSource.Snapshot?
    private var remoteArtwork: NSImage?
    private var remoteArtworkID = -1
    /// Zuletzt angezeigte Daten kamen aus MediaRemote (für Cover-Verwaltung).
    private var lastSourceRemote = false
    /// Spotify-Extras aus AppleScript – an den Titel gebunden, für den sie gelesen wurden.
    private var spotifyExtras: (shuffling: Bool, repeating: Bool, uri: String, title: String, artist: String)?
    /// Kurzlebige optimistische Anzeige nach Play/Pause bzw. Spulen (bis MediaRemote bestätigt).
    private var optimistic: (playing: Bool?, elapsed: Double?, at: Date, until: Date)?
    private var appNames: [String: String] = [:]
    /// Repeat-One nach manuellem Skip: erst auf die erste *neue* URI wieder sperren.
    private var relockFrom: String?
    private var relockDeadline = Date.distantPast
    private var lastReplay = Date.distantPast
    /// Jeder manuelle Skip zählt hoch – nur Abfragen, die *nach* dem letzten Skip
    /// eingereiht wurden, dürfen Repeat-One neu sperren.
    private var skipSeq = 0
    /// Titel, für den das Apple-Music-Cover (AppleScript) zuletzt geladen wurde.
    private var musicArtKey = ""

    /// MediaRemote liefert gerade Daten → diese anzeigen und darüber steuern.
    /// Sonst (nichts gemeldet oder Weg gesperrt) übernimmt AppleScript.
    private var usingRemote: Bool { systemWide && remoteSnap != nil }

    /// Alle Apps, die Web-Links öffnen (Firefox, Zen, Orion … nicht nur die feste Liste).
    private lazy var webHandlerIDs: Set<String> = {
        guard let u = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: u).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }()

    private let queue = DispatchQueue(label: "island.media", qos: .userInitiated)
    private var timer: Timer?
    private var lastKey = ""
    private var lastArtworkURL = ""

    /// Manually (re)trigger the Automation prompt — runs a harmless query against
    /// each running media app, which makes macOS show the consent dialog.
    func requestAutomationPermission() {
        let apps = runningMediaApps()
        queue.async { [weak self] in
            guard let self else { return }
            for app in apps {
                _ = self.runScript("tell application \"\(app)\" to get player state")
            }
        }
    }

    func start() {
        remote.onAvailabilityChange = { [weak self] ok in
            guard let self else { return }
            self.systemWide = ok && AppSettings.shared.systemNowPlaying
            if !self.systemWide { self.leaveRemoteMode() }
            self.poll()
        }
        remote.onUpdate = { [weak self] snap, art in self?.applyRemote(snap, artwork: art) }
        if AppSettings.shared.systemNowPlaying { remote.start() }

        poll()
        let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Beim Beenden: Adapter-Prozess mitbeenden (sonst lebt perl weiter).
    func shutdown() {
        remote.stop(sync: true)
    }

    /// Schalter in den Einstellungen: MediaRemote an/aus.
    func setSystemWide(_ on: Bool) {
        if on {
            remote.start()
        } else {
            remote.stop()
            systemWide = false
            leaveRemoteMode()
            poll()
        }
    }

    /// Zurück zu AppleScript: MediaRemote-Cover & Zustand verwerfen, damit der
    /// AppleScript-Weg sein eigenes Cover neu lädt.
    private func leaveRemoteMode() {
        remoteSnap = nil
        remoteArtwork = nil
        optimistic = nil
        if lastSourceRemote {
            lastSourceRemote = false
            lastKey = ""
            lastArtworkURL = ""
            musicArtKey = ""
            artwork = nil
            accent = Color(white: 0.4)
        }
    }

    // MARK: - MediaRemote (systemweit)

    private func applyRemote(_ snap: MediaRemoteSource.Snapshot?, artwork image: NSImage?) {
        guard systemWide else { return }     // aus: nichts vom Adapter übernehmen
        let artChanged = snap != nil && snap!.artworkID != remoteArtworkID
        if let snap, artChanged {
            remoteArtworkID = snap.artworkID
            remoteArtwork = image          // nil = Cover weg bzw. neues Medium ohne Cover
        }
        // Echter Stand bestätigt die optimistische Anzeige.
        if let o = optimistic, let p = o.playing, snap?.playing == p { optimistic = nil }
        let previousKey = info.trackKey
        remoteSnap = snap
        guard let snap else {
            // MediaRemote meldet nichts → AppleScript entscheidet (evtl. Spotify/Music).
            if lastSourceRemote { lastSourceRemote = false; apply(NowPlaying()) }
            poll()
            return
        }
        let switched = !lastSourceRemote
        if switched { lastArtworkURL = "" }
        lastSourceRemote = true
        musicArtKey = ""
        let np = nowPlaying(from: snap)
        apply(np)
        if artChanged || switched {
            artwork = remoteArtwork
            accent = remoteArtwork.map(Self.dominantColor(of:)) ?? Color(white: 0.4)
        }
        // Spotify-Titelwechsel: URI & Co. sofort nachladen, nicht erst beim nächsten Tick.
        if np.app == "Spotify", np.trackKey != previousKey { refreshSoon() }
    }

    private func nowPlaying(from s: MediaRemoteSource.Snapshot) -> NowPlaying {
        var np = NowPlaying()
        np.app = appName(for: s.bundleID)
        np.title = s.title
        np.artist = s.artist
        np.album = s.album
        np.isPlaying = s.playing
        np.duration = s.duration
        np.position = s.position()
        np.isBrowser = Self.browsers.contains { $0.bundle == s.bundleID } || webHandlerIDs.contains(s.bundleID)
        np.canSeek = s.duration > 0
        if np.app == "Spotify", let x = spotifyExtras {
            np.shuffling = x.shuffling
            np.repeating = x.repeating
            // Nur gültig, wenn sie zu genau diesem Titel gehört – sonst „unbekannt“.
            np.trackURI = (x.title == s.title && x.artist == s.artist) ? x.uri : ""
        } else {
            np.shuffling = (s.shuffle ?? 1) > 1
            np.repeating = (s.repeatMode ?? 1) > 1
        }
        if let o = optimistic {
            if Date() < o.until {
                if let p = o.playing { np.isPlaying = p }
                if let e = o.elapsed {
                    let playing = o.playing ?? s.playing
                    var pos = playing ? e + Date().timeIntervalSince(o.at) * max(s.rate, 0) : e
                    if s.duration > 0 { pos = min(s.duration, pos) }
                    np.position = max(0, pos)
                }
            } else {
                optimistic = nil
            }
        }
        return np
    }

    /// Anzeigename einer App aus der Bundle-ID (bekannte Namen wie im AppleScript-Pfad).
    private func appName(for bundleID: String) -> String {
        switch bundleID {
        case "com.spotify.client": return "Spotify"
        case "com.apple.Music": return "Music"
        case "": return "Wiedergabe"
        default: break
        }
        if let b = Self.browsers.first(where: { $0.bundle == bundleID }) { return b.name }
        if let cached = appNames[bundleID] { return cached }
        var name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        appNames[bundleID] = name
        return name
    }

    /// Im MediaRemote-Modus: Position hochzählen und – nur bei Spotify – die
    /// Extras (Shuffle/Repeat/Track-URI) per AppleScript nachladen.
    private func tickRemote(apps: Set<String>) {
        if let s = remoteSnap, s.playing || optimistic != nil { apply(nowPlaying(from: s)) }
        guard info.app == "Spotify", apps.contains("Spotify") else { spotifyExtras = nil; return }
        let seq = skipSeq
        queue.async { [weak self] in
            guard let self, let r = self.querySpotify() else { return }
            DispatchQueue.main.async {
                self.spotifyExtras = (r.shuffling, r.repeating, r.trackURI, r.title, r.artist)
                if seq == self.skipSeq { self.maybeRelock(freshURI: r.trackURI) }
                if self.usingRemote, let s = self.remoteSnap { self.apply(self.nowPlaying(from: s)) }
            }
        }
    }

    // MARK: - Polling

    private func runningMediaApps() -> Set<String> {
        var set = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            switch app.bundleIdentifier {
            case "com.spotify.client": set.insert("Spotify")
            case "com.apple.Music":    set.insert("Music")
            default: break
            }
        }
        return set
    }

    /// Browsers we can read a playing `<video>` from via AppleScript.
    private static let browsers: [(name: String, bundle: String, safari: Bool)] = [
        ("Safari",         "com.apple.Safari",        true),
        ("Google Chrome",  "com.google.Chrome",       false),
        ("Brave Browser",  "com.brave.Browser",       false),
        ("Microsoft Edge", "com.microsoft.edgemac",   false),
        ("Arc",            "company.thebrowser.Browser", false),
        ("Vivaldi",        "com.vivaldi.Vivaldi",     false),
        ("Opera",          "com.operasoftware.Opera", false),
    ]

    private func runningBrowsers() -> [(name: String, bundle: String, safari: Bool)] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return Self.browsers.filter { ids.contains($0.bundle) }
    }

    @Published var permissionDenied = false   // Automation (Apple Events) was refused
    @Published var anyAppRunning = false      // a media app is open right now

    func poll() {
        let apps = runningMediaApps()
        let browsers = runningBrowsers()
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        Self.log("running media apps: \(apps.sorted()) browsers: \(browsers.map { $0.name })")
        let running = !apps.isEmpty || !browsers.isEmpty || remoteSnap != nil
        if anyAppRunning != running { anyAppRunning = running }
        if usingRemote { tickRemote(apps: apps); return }
        let currentApp = info.app
        let seq = skipSeq
        queue.async { [weak self] in
            guard let self else { return }
            var candidates: [NowPlaying] = []
            if apps.contains("Spotify"), let r = self.querySpotify(), r.hasTrack { candidates.append(r) }
            if apps.contains("Music"), let r = self.queryMusic(), r.hasTrack { candidates.append(r) }
            for b in browsers {
                if let r = self.queryBrowser(b.name, safari: b.safari, frontmost: b.bundle == frontBundle) {
                    candidates.append(r)
                }
            }
            let resolved = self.pick(candidates, current: currentApp)
            Self.log("resolved: app=\(resolved.app) title=\(resolved.title) playing=\(resolved.isPlaying) browser=\(resolved.isBrowser)")
            DispatchQueue.main.async {
                // Inzwischen liefert MediaRemote → verspätetes AppleScript-Ergebnis verwerfen.
                guard !self.usingRemote else { return }
                self.lastSourceRemote = false
                if resolved.app == "Spotify", seq == self.skipSeq { self.maybeRelock(freshURI: resolved.trackURI) }
                self.apply(resolved)
            }
        }
    }

    /// Choose the source to show: keep the current one if it's still playing
    /// (anti-flicker), otherwise prefer a playing music app, then any playing
    /// source (a browser video), then whatever has a track.
    private func pick(_ candidates: [NowPlaying], current: String) -> NowPlaying {
        guard !candidates.isEmpty else { return NowPlaying() }
        if let same = candidates.first(where: { $0.app == current && $0.isPlaying }) { return same }
        if let music = candidates.first(where: { $0.isPlaying && !$0.isBrowser }) { return music }
        if let playing = candidates.first(where: { $0.isPlaying }) { return playing }
        if let same = candidates.first(where: { $0.app == current }) { return same }
        return candidates.first ?? NowPlaying()
    }

    private func apply(_ np: NowPlaying) {
        let changed = np.hasTrack && np.trackKey != lastKey
        info = np
        updateMediaPeek(np)

        if !np.artworkURL.isEmpty {
            if np.artworkURL != lastArtworkURL {
                lastArtworkURL = np.artworkURL
                loadArtwork(from: np.artworkURL)
            }
        } else if np.app != "Music", np.hasTrack, !lastArtworkURL.isEmpty {
            // Moved to a source without art (e.g. a non-YouTube video) → clear it.
            lastArtworkURL = ""
            artwork = nil
            accent = Color(white: 0.4)
        }
        if !np.hasTrack {
            artwork = nil
            accent = Color(white: 0.4)
            lastArtworkURL = ""
        }

        // Spotify "repeat one" emulation (Spotify's AppleScript has no native repeat-one).
        // Nur mit bekannter URI, nur während der Wiedergabe und gedrosselt – sonst
        // startet der Song bei veralteten Daten mehrfach neu.
        if repeatMode == .one, np.app == "Spotify", !lockedURI.isEmpty, np.hasTrack, !np.trackURI.isEmpty {
            if np.trackURI != lockedURI {
                if np.isPlaying, Date().timeIntervalSince(lastReplay) > 2 {
                    lastReplay = Date()
                    spotify("play track \"\(lockedURI)\"")   // advanced off the song → replay it
                }
            } else if np.isPlaying, np.duration > 0, (np.duration - np.position) < 1.8,
                      Date().timeIntervalSince(lastReplay) > 2 {
                lastReplay = Date()
                seekRaw(0)                                // near the end → loop back to start
            }
        }

        // Apple-Music-Cover (AppleScript-Weg) genau einmal pro Titel laden – auch
        // nach einem Wechsel von MediaRemote zurück auf denselben Titel.
        if np.app == "Music", np.hasTrack, !lastSourceRemote, np.trackKey != musicArtKey {
            musicArtKey = np.trackKey
            loadMusicArtwork()
        }

        if changed {
            lastKey = np.trackKey
            onTrackChanged?()
        }
    }

    /// Decides whether the compact peek shows, with a 5 s grace after pausing.
    private func updateMediaPeek(_ np: NowPlaying) {
        let playing = np.isPlaying && np.hasTrack
        if playing {
            pauseHideWork?.cancel(); pauseHideWork = nil
            if !showMediaPeek { withAnimation(.island) { showMediaPeek = true } }
        } else if np.hasTrack {
            // Paused (or stopped with a track loaded).
            let justPaused = prevPlaying            // was playing, now paused
            let justAppeared = !prevHasTrack        // a track just got loaded
            if justPaused || justAppeared {
                withAnimation(.island) { showMediaPeek = true }
                scheduleHide()
            }
            // Otherwise keep the current visibility (once hidden, stay hidden).
        } else {
            pauseHideWork?.cancel(); pauseHideWork = nil
            if showMediaPeek { withAnimation(.island) { showMediaPeek = false } }
        }
        prevPlaying = playing
        prevHasTrack = np.hasTrack
    }

    private func scheduleHide() {
        pauseHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.island) { self.showMediaPeek = false }
            self.pauseHideWork = nil
        }
        pauseHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    // MARK: - Transport controls

    func playPause() {
        if usingRemote {
            remote.send(.togglePlayPause)
            let now = Date()
            let cur = remoteSnap
            optimistic = (!(cur?.playing ?? info.isPlaying), cur?.position(at: now) ?? info.position, now, now + 1.5)
            if let s = remoteSnap { apply(nowPlaying(from: s)) }
            return
        }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){if(v.paused){v.play()}else{v.pause()}}") }
        else { send("playpause") }
        refreshSoon()
    }
    func play() {
        if usingRemote { remote.send(.play); return }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.play()}") }
        else { send("play") }
        refreshSoon()
    }
    func pause() {
        if usingRemote { remote.send(.pause); return }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.pause()}") }
        else { send("pause") }
        refreshSoon()
    }
    func next() {
        if usingRemote {
            if info.isBrowser { seek(to: info.position + 10) }
            // Spotify per AppleScript (seriell mit der URI-Abfrage) – nur wenn das
            // nachweislich klappt; sonst (keine Automation-Freigabe) MediaRemote.
            else if info.app == "Spotify", spotifyExtras != nil, !permissionDenied { send("next track"); deferRelock() }
            else { remote.send(.nextTrack) }
            return
        }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.currentTime=Math.min(v.duration||1e9,v.currentTime+10)}"); refreshSoon() }
        else { send("next track"); deferRelock() }
    }
    func previous() {
        if usingRemote {
            if info.isBrowser { seek(to: info.position - 10) }
            else if info.app == "Spotify", spotifyExtras != nil, !permissionDenied { send("previous track"); deferRelock() }
            else { remote.send(.previousTrack) }
            return
        }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.currentTime=Math.max(0,v.currentTime-10)}"); refreshSoon() }
        else { send("previous track"); deferRelock() }
    }
    /// Skip to the next item — next video on YouTube, next track on Spotify/Music.
    func skipNext() {
        if usingRemote, info.isBrowser { remote.send(.nextTrack); return }
        if info.isBrowser {
            browserCommand("var b=document.querySelector('.ytp-next-button');if(b&&b.getAttribute('aria-disabled')!=='true'){b.click()}else{var v=document.querySelector('video');if(v)v.currentTime=v.duration}")
            refreshSoon()
        } else { next() }
    }
    /// Skip to the previous item — previous video on YouTube, previous track otherwise.
    func skipPrevious() {
        if usingRemote, info.isBrowser { remote.send(.previousTrack); return }
        if info.isBrowser {
            browserCommand("var b=document.querySelector('.ytp-prev-button');if(b&&b.getAttribute('aria-disabled')!=='true'){b.click()}else{var v=document.querySelector('video');if(v)v.currentTime=0}")
            refreshSoon()
        } else { previous() }
    }
    func setShuffle(_ on: Bool) { spotify("set shuffling to \(on)"); refreshSoon() }

    /// Seek to an absolute position (seconds) — used by the draggable scrubber.
    func seek(to seconds: Double) {
        if usingRemote {
            remote.seek(to: seconds)
            let now = Date()
            optimistic = (optimistic?.playing, max(0, seconds), now, now + 1.5)
            if let s = remoteSnap { apply(nowPlaying(from: s)) } else { info.position = max(0, seconds) }
            return
        }
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.currentTime=\(Int(max(0, seconds)))}") }
        else { seekRaw(seconds) }
        info.position = max(0, seconds)   // optimistic
    }

    private func seekRaw(_ seconds: Double) {
        let app = info.app.isEmpty ? "Spotify" : info.app
        let src = "if application \"\(app)\" is running then\n  tell application \"\(app)\" to set player position to \(max(0, seconds))\nend if"
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    // Repeat cycle: off → all (Playlist) → one (Song) → off
    func cycleRepeat() {
        switch repeatMode {
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        if info.app == "Music" {
            let v = mode == .off ? "off" : (mode == .one ? "one" : "all")
            musicCommand("set song repeat to \(v)")   // Music supports repeat-one natively
        } else if usingRemote, info.app != "Spotify" {
            remote.setRepeat(mode == .off ? 1 : (mode == .one ? 2 : 3))
        } else {
            spotify("set repeating to \(mode != .off)")
            lockedURI = mode == .one ? info.trackURI : ""   // Spotify: emulate repeat-one
            if mode == .one, lockedURI.isEmpty {
                // URI noch unbekannt (MediaRemote-Modus) → bei der ersten frischen sperren.
                relockFrom = ""
                relockDeadline = Date()
            } else if mode != .one {
                relockFrom = nil
            }
        }
        refreshSoon()
    }

    private func musicCommand(_ cmd: String) {
        let src = "if application \"Music\" is running then\n  tell application \"Music\" to \(cmd)\nend if"
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    /// After a manual skip while in repeat-one: disable the replay and re-lock on the
    /// first *fresh* Spotify URI that differs from the old one (or after a timeout).
    private func deferRelock() {
        guard repeatMode == .one, info.app == "Spotify" else { refreshSoon(); return }
        skipSeq &+= 1
        // Läuft schon ein Relock (Doppel-Skip), den ursprünglichen Ausgangstitel behalten.
        if relockFrom == nil || relockFrom?.isEmpty == true {
            relockFrom = lockedURI.isEmpty ? info.trackURI : lockedURI
        }
        relockDeadline = Date().addingTimeInterval(2.5)
        lockedURI = ""
        refreshSoon()
    }

    /// Nur mit frisch per AppleScript gelesenen Spotify-Daten aufrufen.
    private func maybeRelock(freshURI uri: String) {
        guard let from = relockFrom, repeatMode == .one, !uri.isEmpty else { return }
        if uri != from || Date() > relockDeadline {
            lockedURI = uri
            relockFrom = nil
        }
    }

    private func send(_ command: String) {
        let app = info.app.isEmpty ? "Spotify" : info.app
        let src = "if application \"\(app)\" is running then\n  tell application \"\(app)\" to \(command)\nend if"
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.poll() }
    }

    // MARK: - Spotify extras (shuffle / repeat / playlist)

    func toggleShuffle() { spotify("set shuffling to \(!info.shuffling)"); refreshSoon() }

    /// Start playing a Spotify URI — works for tracks, albums and playlists,
    /// e.g. "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M".
    func playURI(_ uri: String) {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        spotify("play track \"\(trimmed)\"")
        deferRelock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.poll() }
    }

    private func spotify(_ command: String) {
        let src = "if application \"Spotify\" is running then\n  tell application \"Spotify\" to \(command)\nend if"
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    // MARK: - AppleScript queries

    private func querySpotify() -> NowPlaying? {
        let src = """
        if application "Spotify" is running then
          tell application "Spotify"
            try
              set pstate to player state as string
              set trackName to name of current track
              set trackArtist to artist of current track
              set trackAlbum to album of current track
              set trackDur to duration of current track
              set trackPos to player position
              set artURL to artwork url of current track
              set shuf to shuffling
              set rep to repeating
              set trackURI to spotify url of current track
              return pstate & linefeed & trackName & linefeed & trackArtist & linefeed & trackAlbum & linefeed & (trackDur as string) & linefeed & (trackPos as string) & linefeed & artURL & linefeed & (shuf as string) & linefeed & (rep as string) & linefeed & trackURI
            on error
              return ""
            end try
          end tell
        end if
        """
        guard let out = runScript(src), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 7 else { return nil }
        var np = NowPlaying()
        np.app = "Spotify"
        np.isPlaying = parts[0] == "playing"
        np.title = parts[1]
        np.artist = parts[2]
        np.album = parts[3]
        np.duration = (Double(parts[4]) ?? 0) / 1000.0   // Spotify reports ms
        np.position = Double(parts[5]) ?? 0
        np.artworkURL = parts[6]
        np.shuffling = parts.count > 7 && parts[7] == "true"
        np.repeating = parts.count > 8 && parts[8] == "true"
        np.trackURI = parts.count > 9 ? parts[9] : ""
        return np
    }

    private func queryMusic() -> NowPlaying? {
        let src = """
        if application "Music" is running then
          tell application "Music"
            try
              if player state is stopped then return ""
              set pstate to player state as string
              set trackName to name of current track
              set trackArtist to artist of current track
              set trackAlbum to album of current track
              set trackDur to duration of current track
              set trackPos to player position
              return pstate & linefeed & trackName & linefeed & trackArtist & linefeed & trackAlbum & linefeed & (trackDur as string) & linefeed & (trackPos as string)
            on error
              return ""
            end try
          end tell
        end if
        """
        guard let out = runScript(src), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        var np = NowPlaying()
        np.app = "Music"
        np.isPlaying = parts[0] == "playing"
        np.title = parts[1]
        np.artist = parts[2]
        np.album = parts[3]
        np.duration = Double(parts[4]) ?? 0    // Music reports seconds
        np.position = Double(parts[5]) ?? 0
        np.artworkURL = ""                      // Apple Music artwork isn't URL-addressable
        return np
    }

    // MARK: - Browser video (YouTube, Netflix, …)

    /// Reads the active tab's `<video>` element. Uses only single quotes and no
    /// backslashes so it can be embedded inside an AppleScript double-quoted string.
    private static let videoJS = "(function(){var v=document.querySelector('video');if(!v)return '';var d=isFinite(v.duration)?Math.floor(v.duration):0;var p=(!v.paused&&!v.ended)?'1':'0';var ce=document.querySelector('ytd-channel-name a');var c=ce?ce.textContent.trim():'';return [p,document.title,c,Math.floor(v.currentTime||0),d].join(String.fromCharCode(10));})()"

    /// True when the current source is a browser video (vs Spotify/Music).
    var isBrowserSource: Bool { info.isBrowser }

    /// Queries one browser's front tab. With "Allow JavaScript from Apple Events"
    /// enabled we get the live play state + progress; otherwise we still surface the
    /// title + thumbnail of the video the user is actively watching (front browser).
    private func queryBrowser(_ name: String, safari: Bool, frontmost: Bool) -> NowPlaying? {
        let js = Self.videoJS
        let getURL   = safari ? "URL of current tab of front window"  : "URL of active tab of front window"
        let getTitle = safari ? "name of current tab of front window" : "title of active tab of front window"
        let exec     = safari ? "do JavaScript \"\(js)\" in current tab of front window"
                              : "execute (active tab of front window) javascript \"\(js)\""
        let src = """
        if application "\(name)" is running then
          tell application "\(name)"
            try
              if (count of windows) is 0 then return ""
              set u to \(getURL)
              set ti to \(getTitle)
              set r to ""
              try
                set r to (\(exec))
              end try
              return u & linefeed & ti & linefeed & r
            on error
              return ""
            end try
          end tell
        end if
        """
        guard let out = runScript(src), !out.isEmpty else { return nil }
        let lines = out.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        let url = lines[0]
        let tabTitle = lines[1]
        Self.log("browser \(name): front=\(frontmost) jsLines=\(lines.count) url=\(url)")

        // JS path: url, title, then [playing, jsTitle, channel, pos, dur].
        if lines.count >= 7, lines[2] == "0" || lines[2] == "1" {
            var np = NowPlaying()
            np.app = name
            np.isBrowser = true
            np.canSeek = (Double(lines[6]) ?? 0) > 0   // 0 for live streams → display-only
            np.isPlaying = lines[2] == "1"
            np.title = cleanVideoTitle(lines[3].isEmpty ? tabTitle : lines[3])
            let site = siteName(from: url)
            np.artist = lines[4].isEmpty ? site : lines[4]
            np.album = site
            np.position = Double(lines[5]) ?? 0
            np.duration = Double(lines[6]) ?? 0
            np.artworkURL = youtubeThumbnail(from: url)
            return np.hasTrack ? np : nil
        }

        // No JS: only show the video the user is actively looking at.
        guard frontmost, isVideoURL(url) else { return nil }
        var np = NowPlaying()
        np.app = name
        np.isBrowser = true
        np.canSeek = false
        np.isPlaying = true          // optimistic — real state needs JS
        np.title = cleanVideoTitle(tabTitle)
        np.album = siteName(from: url)
        np.artist = np.album
        np.artworkURL = youtubeThumbnail(from: url)
        return np.hasTrack ? np : nil
    }

    /// Runs a tiny JS snippet against the current browser source's front tab.
    private func browserCommand(_ js: String) {
        guard info.isBrowser else { return }
        let app = info.app
        let safari = app == "Safari"
        let wrapped = "(function(){\(js)})()"
        let exec = safari ? "do JavaScript \"\(wrapped)\" in current tab of front window"
                          : "execute (active tab of front window) javascript \"\(wrapped)\""
        let src = """
        if application "\(app)" is running then
          tell application "\(app)"
            try
              \(exec)
            end try
          end tell
        end if
        """
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    private func cleanVideoTitle(_ t: String) -> String {
        var s = t
        for suffix in [" - YouTube", " - YouTube Music", " on Vimeo", " | Netflix", " - Twitch"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        if let r = s.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func siteName(from url: String) -> String {
        guard let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") else { return "Video" }
        let map = ["youtube.com": "YouTube", "youtu.be": "YouTube", "music.youtube.com": "YouTube Music",
                   "netflix.com": "Netflix", "vimeo.com": "Vimeo", "twitch.tv": "Twitch",
                   "disneyplus.com": "Disney+", "primevideo.com": "Prime Video",
                   "tv.apple.com": "Apple TV", "dailymotion.com": "Dailymotion"]
        if let n = map[host] { return n }
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    private func isVideoURL(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.replacingOccurrences(of: "www.", with: "") else { return false }
        if host.contains("youtube.com") {
            return comps.path == "/watch" || comps.path.hasPrefix("/shorts/") || comps.path.hasPrefix("/live/")
        }
        if host == "youtu.be" { return comps.path.count > 1 }
        let hosts = ["music.youtube.com", "netflix.com", "vimeo.com", "twitch.tv",
                     "disneyplus.com", "primevideo.com", "tv.apple.com", "dailymotion.com"]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func youtubeThumbnail(from url: String) -> String {
        guard let comps = URLComponents(string: url) else { return "" }
        let host = comps.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        var id = ""
        if host.contains("youtube.com") {
            if comps.path == "/watch" { id = comps.queryItems?.first(where: { $0.name == "v" })?.value ?? "" }
            else if comps.path.hasPrefix("/shorts/") { id = String(comps.path.dropFirst("/shorts/".count)) }
            else if comps.path.hasPrefix("/live/") { id = String(comps.path.dropFirst("/live/".count)) }
        } else if host == "youtu.be" {
            id = String(comps.path.dropFirst())
        }
        id = id.split(separator: "/").first.map(String.init) ?? id
        return id.isEmpty ? "" : "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }

    static let debug = ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1"
    static func log(_ s: String) {
        guard debug else { return }
        FileHandle.standardError.write(("‹media› " + s + "\n").data(using: .utf8)!)
    }

    /// Runs an AppleScript. Sending the first event to an un-authorized app makes
    /// macOS show the Automation prompt; a denial returns error −1743 which we
    /// surface to the UI.
    @discardableResult
    private func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let num = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
            Self.log("AppleScript error \(num): \(error["NSAppleScriptErrorMessage"] ?? "")")
            if num == -1743 {
                DispatchQueue.main.async { if !self.permissionDenied { self.permissionDenied = true } }
            }
            return nil
        }
        DispatchQueue.main.async { if self.permissionDenied { self.permissionDenied = false } }
        return result.stringValue
    }

    // MARK: - Artwork + accent color

    /// Apple Music exposes artwork only as raw bytes, so dump it to a temp file and load it.
    private func loadMusicArtwork() {
        let path = NSTemporaryDirectory() + "island_music_art.tiff"
        let src = """
        if application "Music" is running then
          tell application "Music"
            try
              set artData to data of (first artwork of current track)
              set tmpFile to POSIX file "\(path)"
              set fh to open for access tmpFile with write permission
              set eof fh to 0
              write artData to fh
              close access fh
              return "ok"
            on error
              try
                close access tmpFile
              end try
              return ""
            end try
          end tell
        end if
        """
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.runScript(src) == "ok"
            guard ok, let image = NSImage(contentsOfFile: path) else {
                DispatchQueue.main.async {
                    guard !self.lastSourceRemote else { return }   // inzwischen MediaRemote
                    self.artwork = nil; self.accent = Color(white: 0.4)
                }
                return
            }
            let color = Self.dominantColor(of: image)
            DispatchQueue.main.async {
                guard !self.lastSourceRemote else { return }
                self.artwork = image
                self.accent = color
            }
        }
    }

    private func loadArtwork(from urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            artwork = nil
            accent = Color(white: 0.4)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data) else { return }
            let color = Self.dominantColor(of: image)
            DispatchQueue.main.async {
                // Verspätet? (anderer Titel oder inzwischen MediaRemote)
                guard !self.lastSourceRemote, self.lastArtworkURL == urlString else { return }
                self.artwork = image
                self.accent = color
            }
        }.resume()
    }

    /// Average color, nudged toward vividness, for the accent glow.
    static func dominantColor(of image: NSImage) -> Color {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let small = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return Color(white: 0.4) }

        let ctx = NSGraphicsContext(bitmapImageRep: small)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rep.draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        NSGraphicsContext.restoreGraphicsState()

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for x in 0..<8 {
            for y in 0..<8 {
                guard let c = small.colorAt(x: x, y: y) else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
        }
        guard n > 0 else { return Color(white: 0.4) }
        r /= n; g /= n; b /= n

        // Boost saturation a little so the glow reads as an accent.
        let base = NSColor(red: r, green: g, blue: b, alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return Color(nsColor: base) }
        let sat = min(1.0, hsb.saturationComponent * 1.4)
        let bri = max(0.45, hsb.brightnessComponent)
        let boosted = NSColor(hue: hsb.hueComponent, saturation: sat, brightness: bri, alpha: 1)
        return Color(nsColor: boosted)
    }
}

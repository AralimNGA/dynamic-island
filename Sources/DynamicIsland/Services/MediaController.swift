import AppKit
import SwiftUI
import Combine

struct NowPlaying: Equatable {
    var app: String = ""          // "Spotify" | "Music"
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0      // seconds
    var position: Double = 0      // seconds
    var artworkURL: String = ""
    var shuffling = false
    var repeating = false
    var trackURI = ""

    var hasTrack: Bool { !title.isEmpty }
    var trackKey: String { app + "|" + title + "|" + artist }
}

/// Reads system media state from Spotify / Apple Music via AppleScript and sends
/// transport commands. The private MediaRemote framework is blocked for third
/// parties on macOS 15.4+, so per-app scripting is the robust path.
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
        poll()
        let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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

    @Published var permissionDenied = false   // Automation (Apple Events) was refused
    @Published var anyAppRunning = false      // a media app is open right now

    func poll() {
        let apps = runningMediaApps()
        Self.log("running media apps: \(apps.sorted())")
        let running = !apps.isEmpty
        if anyAppRunning != running { anyAppRunning = running }
        queue.async { [weak self] in
            guard let self else { return }
            var best: NowPlaying?
            if apps.contains("Spotify"), let r = self.querySpotify(), r.hasTrack {
                best = r
            }
            if apps.contains("Music"), let r = self.queryMusic(), r.hasTrack {
                // Prefer whichever is actually playing.
                if r.isPlaying || best == nil || !(best?.isPlaying ?? false) {
                    if r.isPlaying || best == nil { best = r }
                }
            }
            let resolved = best ?? NowPlaying()
            Self.log("resolved: app=\(resolved.app) title=\(resolved.title) playing=\(resolved.isPlaying)")
            DispatchQueue.main.async { self.apply(resolved) }
        }
    }

    private func apply(_ np: NowPlaying) {
        let changed = np.hasTrack && np.trackKey != lastKey
        info = np
        updateMediaPeek(np)

        if np.app == "Spotify", np.artworkURL != lastArtworkURL {
            lastArtworkURL = np.artworkURL
            loadArtwork(from: np.artworkURL)
        }
        if !np.hasTrack {
            artwork = nil
            accent = Color(white: 0.4)
            lastArtworkURL = ""
        }

        // Spotify "repeat one" emulation (Spotify's AppleScript has no native repeat-one).
        if repeatMode == .one, np.app == "Spotify", !lockedURI.isEmpty, np.hasTrack {
            if np.trackURI != lockedURI {
                spotify("play track \"\(lockedURI)\"")   // advanced off the song → replay it
            } else if np.isPlaying, np.duration > 0, (np.duration - np.position) < 1.8 {
                seekRaw(0)                                // near the end → loop back to start
            }
        }

        if changed {
            lastKey = np.trackKey
            if np.app == "Music" { loadMusicArtwork() }
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

    func playPause() { send("playpause"); refreshSoon() }
    func play()      { send("play"); refreshSoon() }
    func pause()     { send("pause"); refreshSoon() }
    func next()      { send("next track"); deferRelock() }
    func previous()  { send("previous track"); deferRelock() }
    func setShuffle(_ on: Bool) { spotify("set shuffling to \(on)"); refreshSoon() }

    /// Seek to an absolute position (seconds) — used by the draggable scrubber.
    func seek(to seconds: Double) {
        seekRaw(seconds)
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
        } else {
            spotify("set repeating to \(mode != .off)")
            lockedURI = mode == .one ? info.trackURI : ""   // Spotify: emulate repeat-one
        }
        refreshSoon()
    }

    private func musicCommand(_ cmd: String) {
        let src = "if application \"Music\" is running then\n  tell application \"Music\" to \(cmd)\nend if"
        queue.async { [weak self] in _ = self?.runScript(src) }
    }

    /// After a manual skip while in repeat-one, briefly disable the replay and re-lock.
    private func deferRelock() {
        guard repeatMode == .one, info.app == "Spotify" else { refreshSoon(); return }
        lockedURI = ""
        refreshSoon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.repeatMode == .one else { return }
            self.lockedURI = self.info.trackURI
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
                DispatchQueue.main.async { self.artwork = nil; self.accent = Color(white: 0.4) }
                return
            }
            let color = Self.dominantColor(of: image)
            DispatchQueue.main.async {
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

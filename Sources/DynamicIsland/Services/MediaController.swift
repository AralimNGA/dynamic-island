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
        let running = !apps.isEmpty || !browsers.isEmpty
        if anyAppRunning != running { anyAppRunning = running }
        let currentApp = info.app
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
            DispatchQueue.main.async { self.apply(resolved) }
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

    func playPause() {
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){if(v.paused){v.play()}else{v.pause()}}") }
        else { send("playpause") }
        refreshSoon()
    }
    func play() {
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.play()}") }
        else { send("play") }
        refreshSoon()
    }
    func pause() {
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.pause()}") }
        else { send("pause") }
        refreshSoon()
    }
    func next() {
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.currentTime=Math.min(v.duration||1e9,v.currentTime+10)}"); refreshSoon() }
        else { send("next track"); deferRelock() }
    }
    func previous() {
        if info.isBrowser { browserCommand("var v=document.querySelector('video');if(v){v.currentTime=Math.max(0,v.currentTime-10)}"); refreshSoon() }
        else { send("previous track"); deferRelock() }
    }
    /// Skip to the next item — next video on YouTube, next track on Spotify/Music.
    func skipNext() {
        if info.isBrowser {
            browserCommand("var b=document.querySelector('.ytp-next-button');if(b&&b.getAttribute('aria-disabled')!=='true'){b.click()}else{var v=document.querySelector('video');if(v)v.currentTime=v.duration}")
            refreshSoon()
        } else { next() }
    }
    /// Skip to the previous item — previous video on YouTube, previous track otherwise.
    func skipPrevious() {
        if info.isBrowser {
            browserCommand("var b=document.querySelector('.ytp-prev-button');if(b&&b.getAttribute('aria-disabled')!=='true'){b.click()}else{var v=document.querySelector('video');if(v)v.currentTime=0}")
            refreshSoon()
        } else { previous() }
    }
    func setShuffle(_ on: Bool) { spotify("set shuffling to \(on)"); refreshSoon() }

    /// Seek to an absolute position (seconds) — used by the draggable scrubber.
    func seek(to seconds: Double) {
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

import AppKit

/// Test-only: drives the island through several states and renders each to a PNG
/// in-process (no Screen Recording permission needed), then quits.
final class SnapshotRunner {
    private let dir: String
    private let state: IslandState
    private let media: MediaController
    private let timer: TimerModel
    private let shelf: ShelfModel
    private let todo: TodoModel
    private let claude: ClaudeService
    private let view: NSView

    init(dir: String, state: IslandState, media: MediaController, timer: TimerModel,
         shelf: ShelfModel, todo: TodoModel, claude: ClaudeService, view: NSView) {
        self.dir = dir
        self.state = state
        self.media = media
        self.timer = timer
        self.shelf = shelf
        self.todo = todo
        self.claude = claude
        self.view = view
    }

    func run() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fakeTrack = NowPlaying(app: "Spotify", title: "Blinding Lights",
                                   artist: "The Weeknd", album: "After Hours",
                                   isPlaying: true, duration: 200, position: 82, artworkURL: "",
                                   shuffling: true, repeating: false)

        var fakeVideoJS = NowPlaying(app: "Safari", title: "H Y P E (Official Video)",
                                     artist: "The Midnight", album: "YouTube",
                                     isPlaying: true, duration: 243, position: 95, artworkURL: "")
        fakeVideoJS.isBrowser = true; fakeVideoJS.canSeek = true

        var fakeVideoNoJS = NowPlaying(app: "Safari", title: "H Y P E (Official Video)",
                                       artist: "YouTube", album: "YouTube",
                                       isPlaying: true, artworkURL: "")
        fakeVideoNoJS.isBrowser = true; fakeVideoNoJS.canSeek = false

        // A stand-in 16:9 thumbnail so the artwork reads like a video frame.
        let thumb = NSImage(size: NSSize(width: 192, height: 108))
        thumb.lockFocus()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.35, alpha: 1),
            NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.40, alpha: 1),
        ])!.draw(in: NSRect(x: 0, y: 0, width: 192, height: 108), angle: -45)
        NSColor(white: 1, alpha: 0.92).setFill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 84, y: 38)); p.line(to: NSPoint(x: 84, y: 70))
        p.line(to: NSPoint(x: 114, y: 54)); p.close(); p.fill()
        thumb.unlockFocus()

        let steps: [(String, () -> Void)] = [
            ("1_collapsed", {
                self.state.pinnedOpen = false
                self.media.info = NowPlaying()
                self.state.transientActivity = .idle
            }),
            ("2_media_peek", {
                self.state.pinnedOpen = false
                self.media.info = fakeTrack
                self.media.accent = .pink
                self.media.showMediaPeek = true
            }),
            ("3_charging_peek", {
                self.media.info = NowPlaying()
                self.state.transientActivity = .charging(percent: 82, full: false)
            }),
            ("4_expanded_music", {
                self.state.transientActivity = .idle
                self.media.info = fakeTrack
                self.media.accent = .pink
                self.state.selectedTab = .nowPlaying
                self.state.pinnedOpen = true
            }),
            ("5_expanded_timer", {
                self.timer.startCountdown(seconds: 125)
                self.state.selectedTab = .timer
            }),
            ("6_expanded_shelf", {
                self.timer.stop()
                self.state.selectedTab = .shelf
            }),
            ("7_expanded_calendar", {
                self.state.selectedTab = .calendar
            }),
            ("8_expanded_claude", {
                self.state.selectedTab = .claude
            }),
            ("9_expanded_recorder", {
                self.state.selectedTab = .recorder
            }),
            ("10_expanded_shelf_airdrop", {
                let readme = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/DynamicIsland/README.md")
                if FileManager.default.fileExists(atPath: readme.path) {
                    self.shelf.add(urls: [readme])
                }
                self.state.selectedTab = .shelf
            }),
            ("11_expanded_todo", {
                if self.todo.items.isEmpty {
                    self.todo.add("Milch kaufen")
                    self.todo.add("Präsentation fertig machen")
                    self.todo.add("Zahnarzttermin")
                    self.todo.items[2].done = true
                }
                self.state.selectedTab = .todo
            }),
            ("13_video_js", {
                self.media.info = fakeVideoJS
                self.media.artwork = thumb
                self.media.accent = .purple
                self.state.selectedTab = .nowPlaying
            }),
            ("14_video_nojs", {
                self.media.info = fakeVideoNoJS
                self.media.artwork = thumb
                self.media.accent = .purple
                self.state.selectedTab = .nowPlaying
            }),
            ("15_video_peek", {
                self.state.pinnedOpen = false
                self.media.info = fakeVideoNoJS
                self.media.artwork = thumb
                self.media.accent = .purple
                self.media.showMediaPeek = true
            }),
            ("16_ai_pending", {
                self.state.pinnedOpen = true
                self.media.showMediaPeek = false
                self.claude.turns = [
                    .init(role: "user", text: "Leere bitte den Papierkorb"),
                    .init(role: "assistant", text: "Klar, ich leere den Papierkorb für dich."),
                ]
                self.claude.pendingAction = .init(toolName: "empty_trash",
                                                  title: "Papierkorb leeren?",
                                                  detail: "Das lässt sich nicht rückgängig machen.")
                self.state.selectedTab = .claude
            }),
        ]

        var delay = 0.5
        for (name, setup) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                setup()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.9) {
                self.capture(named: name)
            }
            delay += 1.2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private func capture(named name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("snapshot: \(path)\n".data(using: .utf8)!)
    }
}

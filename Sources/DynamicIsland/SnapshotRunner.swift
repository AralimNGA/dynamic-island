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
    private let view: NSView

    init(dir: String, state: IslandState, media: MediaController, timer: TimerModel,
         shelf: ShelfModel, todo: TodoModel, view: NSView) {
        self.dir = dir
        self.state = state
        self.media = media
        self.timer = timer
        self.shelf = shelf
        self.todo = todo
        self.view = view
    }

    func run() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fakeTrack = NowPlaying(app: "Spotify", title: "Blinding Lights",
                                   artist: "The Weeknd", album: "After Hours",
                                   isPlaying: true, duration: 200, position: 82, artworkURL: "",
                                   shuffling: true, repeating: false)

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

import SwiftUI

/// Executes island-control commands emitted by the Claude assistant, e.g.
/// `timer:5`, `tab:todos`, `play`, `accent:blue`, `todo:add:Milch kaufen`.
/// Always invoked on the main thread (from ClaudeService's main-queue completion).
final class IslandCommandRouter {
    private let state: IslandState
    private let media: MediaController
    private let timer: TimerModel
    private let todo: TodoModel
    private let settings: AppSettings

    init(state: IslandState, media: MediaController, timer: TimerModel,
         todo: TodoModel, settings: AppSettings) {
        self.state = state
        self.media = media
        self.timer = timer
        self.todo = todo
        self.settings = settings
    }

    func handle(_ raw: String) {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cmd = parts.first?.lowercased(), !cmd.isEmpty else { return }
        let a1 = parts.count > 1 ? parts[1] : ""
        let a2 = parts.count > 2 ? parts[2] : ""

        switch cmd {
        case "tab":
            if let t = tab(for: a1) { open(t) }
        case "timer":
            if let m = Double(a1.replacingOccurrences(of: ",", with: ".")) {
                timer.startCountdown(seconds: m * 60); open(.timer)
            }
        case "play":     media.play()
        case "pause":    media.pause()
        case "next":     media.next()
        case "previous", "prev": media.previous()
        case "shuffle":  media.setShuffle(a1.lowercased() != "off")
        case "repeat":
            let a = a1.lowercased()
            media.setRepeatMode(a == "off" ? .off : (a == "one" || a == "song" ? .one : .all))
        case "accent":
            if AppSettings.accentOptions.contains(where: { $0.name == a1.lowercased() }) {
                settings.accentName = a1.lowercased()
            }
        case "todo":
            if a1.lowercased() == "add" { todo.add(a2) }
            else if a1.lowercased() == "done" { todo.markDone(matching: a2) }
        case "open":  state.open()
        case "close": state.close()
        default: break
        }
    }

    private func open(_ t: ExpandedTab) {
        settings.setEnabled(t, true)   // make sure the tab is visible
        state.open(t)
    }

    private func tab(for name: String) -> ExpandedTab? {
        switch name.lowercased() {
        case "home", "übersicht", "start": return .home
        case "musik", "music", "nowplaying", "now playing": return .nowPlaying
        case "claude", "ki", "ai", "assistent": return .claude
        case "spiegel", "mirror", "kamera", "camera": return .mirror
        case "aufnahme", "recorder", "record", "mic": return .recorder
        case "ablage", "shelf", "dateien", "files": return .shelf
        case "timer", "stoppuhr": return .timer
        case "todos", "todo", "aufgaben", "tasks": return .todo
        case "kalender", "calendar", "termine": return .calendar
        default: return nil
        }
    }
}

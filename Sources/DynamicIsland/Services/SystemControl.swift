import AppKit

/// The execution layer for assistant tools. Island/media actions go through
/// `IslandCommandRouter`; Mac actions run AppleScript (`NSAppleScript`) or small
/// binaries (`pmset`, `open`, `shortcuts`, `screencapture`, `zsh`) off the main
/// thread. Every input is validated here, the trust boundary for tool calls.
@MainActor
final class SystemControl {
    private let router: IslandCommandRouter
    private let media: MediaController

    init(router: IslandCommandRouter, media: MediaController) {
        self.router = router
        self.media = media
    }

    // MARK: - Central dispatch

    func run(_ name: String, _ input: [String: JSONValue]) async -> ToolOutcome {
        switch name {
        // Island
        case "start_timer":
            guard let m = input["minutes"]?.doubleValue, m > 0 else { return .error("Ungültige Minuten.") }
            router.handle("timer:\(m)"); return .ok("Timer läuft \(formatMinutes(m)).")
        case "open_tab":
            let tab = input["tab"]?.stringValue ?? ""
            router.handle("tab:\(tab)"); return .ok("Tab \(tab) geöffnet.")
        case "set_accent":
            let c = input["color"]?.stringValue ?? ""
            router.handle("accent:\(c)"); return .ok("Akzentfarbe ist jetzt \(c).")
        case "add_todo":
            let t = (input["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return .error("Leerer Aufgabentext.") }
            router.handle("todo:add:\(t)"); return .ok("Aufgabe hinzugefügt: \(t)")
        case "mark_todo_done":
            let t = (input["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return .error("Kein Aufgabentext zum Abhaken.") }
            router.handle("todo:done:\(t)"); return .ok("Aufgabe abgehakt: \(t)")
        case "media_play":     router.handle("play");  return .ok("Wiedergabe fortgesetzt.")
        case "media_pause":    router.handle("pause"); return .ok("Pausiert.")
        case "media_next":     router.handle("next");  return .ok("Nächster Titel.")
        case "media_previous": router.handle("previous"); return .ok("Vorheriger Titel.")
        case "media_shuffle":
            let on = input["on"]?.boolValue ?? false
            router.handle("shuffle:\(on ? "on" : "off")"); return .ok("Zufallswiedergabe \(on ? "an" : "aus").")
        case "media_repeat":
            let mode = input["mode"]?.stringValue ?? "off"
            router.handle("repeat:\(mode)"); return .ok("Wiederholung: \(mode).")

        // Mac read
        case "get_battery_status": return await batteryStatus()
        case "get_volume":         return await volume()
        case "get_now_playing":    return nowPlaying()
        case "list_running_apps":  return await runningApps()
        case "get_frontmost_app":  return await frontmostApp()
        case "get_clipboard":      return clipboard()

        // Mac mutate (safe)
        case "set_volume":      return await setVolume(input["percent"]?.intValue ?? -1)
        case "set_brightness":  return await setBrightness(input["percent"]?.intValue ?? -1)
        case "set_do_not_disturb": return await setDND(input["on"]?.boolValue ?? false)
        case "set_appearance":  return await setAppearance(dark: input["dark"]?.boolValue ?? true)
        case "open_app":        return await openApp(input["name"]?.stringValue ?? "")
        case "open_url":        return openURL(input["url"]?.stringValue ?? "")
        case "web_search":      return webSearch(query: input["query"]?.stringValue ?? "", engine: input["engine"]?.stringValue ?? "google")
        case "set_clipboard":   return setClipboard(input["text"]?.stringValue ?? "")
        case "send_notification": return await sendNotification(title: input["title"]?.stringValue ?? "", body: input["body"]?.stringValue ?? "")
        case "take_screenshot": return await screenshot(input["path"]?.stringValue)

        // Mac mutate (confirm — only reached after the user allows)
        case "quit_app":      return await quitApp(input["name"]?.stringValue ?? "")
        case "sleep_display": return await pmset("displaysleepnow", ok: "Bildschirm im Ruhezustand.")
        case "sleep_system":  return await pmset("sleepnow", ok: "Mac geht in den Ruhezustand.")
        case "lock_screen":   return await lockScreen()
        case "empty_trash":   return await emptyTrash()
        case "run_shortcut":  return await runShortcut(input["name"]?.stringValue ?? "")
        case "run_shell":     return await runShell(input["command"]?.stringValue ?? "")

        default: return .error("Unbekanntes Werkzeug: \(name)")
        }
    }

    // MARK: - Mac read

    private func nowPlaying() -> ToolOutcome {
        guard media.hasTrack else { return .ok("Es läuft gerade nichts.") }
        let i = media.info
        let src = i.isBrowser ? (i.album.isEmpty ? i.app : i.album) : i.app
        return .ok("\(i.title) – \(i.artist) (\(i.isPlaying ? "läuft" : "pausiert"), \(src))")
    }

    private func batteryStatus() async -> ToolOutcome {
        let r = await runProcess("/usr/bin/pmset", ["-g", "batt"])
        let text = r.out
        let pct = text.range(of: #"(\d+)%"#, options: .regularExpression).map { String(text[$0]) } ?? "?"
        let state: String
        if text.contains("AC Power") { state = text.contains("charged") ? "geladen" : "lädt" }
        else { state = "Akku" }
        return .ok("Akku: \(pct) (\(state))")
    }

    private func volume() async -> ToolOutcome {
        let r = await osa("output volume of (get volume settings)")
        return r.ok ? .ok("Lautstärke: \(r.value)%") : .error(r.error)
    }

    private func runningApps() async -> ToolOutcome {
        let r = await osa("""
        set theList to {}
        tell application "System Events" to set theList to name of (every process whose background only is false)
        set AppleScript's text item delimiters to ", "
        return theList as string
        """)
        return r.ok ? .ok("Laufende Apps: \(r.value)") : .error(r.error)
    }

    private func frontmostApp() async -> ToolOutcome {
        let r = await osa("tell application \"System Events\" to get name of first process whose frontmost is true")
        return r.ok ? .ok("Vordergrund: \(r.value)") : .error(r.error)
    }

    private func clipboard() -> ToolOutcome {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            return .ok("Zwischenablage ist leer (oder kein Text).")
        }
        return .ok(String(s.prefix(4000)))
    }

    // MARK: - Mac mutate (safe)

    private func setVolume(_ percent: Int) async -> ToolOutcome {
        guard percent >= 0 else { return .error("Ungültiger Wert.") }
        let p = max(0, min(100, percent))
        let r = await osa("set volume output volume \(p)")
        return r.ok ? .ok("Lautstärke auf \(p)% gesetzt.") : .error(r.error)
    }

    private func setBrightness(_ percent: Int) async -> ToolOutcome {
        guard percent >= 0 else { return .error("Ungültiger Wert.") }
        let p = max(0, min(100, percent))
        let r = await runProcess("/usr/bin/shortcuts", ["run", "Set Brightness"], stdin: "\(p)")
        if r.code == 0 { return .ok("Helligkeit auf \(p)% gesetzt.") }
        return .error("Helligkeit braucht einmalig den Kurzbefehl 'Set Brightness' (Eingabe: Zahl → Helligkeit setzen). Bitte in der App 'Kurzbefehle' anlegen.")
    }

    private func setDND(_ on: Bool) async -> ToolOutcome {
        let r = await runProcess("/usr/bin/shortcuts", ["run", on ? "DND On" : "DND Off"])
        if r.code == 0 { return .ok("'Nicht stören' \(on ? "ein" : "aus")geschaltet.") }
        return .error("Braucht einmalig Kurzbefehle 'DND On' und 'DND Off' (Fokus 'Nicht stören' setzen).")
    }

    private func setAppearance(dark: Bool) async -> ToolOutcome {
        let r = await osa("tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)")
        return r.ok ? .ok(dark ? "Dunkelmodus an." : "Hellmodus an.") : .error(r.error)
    }

    private func openApp(_ name: String) async -> ToolOutcome {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return .error("Kein App-Name.") }
        let r = await runProcess("/usr/bin/open", ["-a", clean])
        return r.code == 0 ? .ok("\(clean) geöffnet.") : .error("App nicht gefunden: \(clean)")
    }

    private func openURL(_ urlString: String) -> ToolOutcome {
        let clean = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: clean), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .error("Nur http/https-URLs erlaubt: \(clean)")
        }
        NSWorkspace.shared.open(url)
        return .ok("Geöffnet: \(clean)")
    }

    private func webSearch(query: String, engine: String) -> ToolOutcome {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let base: String
        switch engine.lowercased() {
        case "youtube":    base = "https://www.youtube.com/results?search_query="
        case "maps":       base = "https://maps.apple.com/?q="
        case "amazon":     base = "https://www.amazon.de/s?k="
        case "duckduckgo": base = "https://duckduckgo.com/?q="
        default:           base = "https://www.google.com/search?q="
        }
        guard let url = URL(string: base + q) else { return .error("Ungültige Suche.") }
        NSWorkspace.shared.open(url)
        return .ok("Suche geöffnet: \(query)")
    }

    private func setClipboard(_ text: String) -> ToolOutcome {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .ok("In die Zwischenablage kopiert.")
    }

    private func sendNotification(title: String, body: String) async -> ToolOutcome {
        let r = await osa("display notification \(literal(body)) with title \(literal(title.isEmpty ? "Dynamic Island" : title))")
        return r.ok ? .ok("Mitteilung angezeigt.") : .error(r.error)
    }

    private func screenshot(_ path: String?) async -> ToolOutcome {
        // Confine output to the Desktop and force a .png filename — never let a
        // model-supplied absolute path overwrite an arbitrary file.
        var filename = "island-shot-\(Int(Date().timeIntervalSince1970)).png"
        if let p = path?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            var name = (p as NSString).lastPathComponent
            if name.isEmpty || name == "/" || name == ".." { name = filename }
            if !name.lowercased().hasSuffix(".png") { name += ".png" }
            filename = name
        }
        let target = NSHomeDirectory() + "/Desktop/" + filename
        let r = await runProcess("/usr/sbin/screencapture", ["-x", target])
        if r.code == 0 { return .ok("Screenshot gespeichert: \(target)") }
        return .error("Screenshot fehlgeschlagen (Bildschirmaufnahme-Recht nötig).")
    }

    // MARK: - Mac mutate (confirm)

    private func quitApp(_ name: String) async -> ToolOutcome {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return .error("Kein App-Name.") }
        let r = await osa("tell application \(literal(clean)) to quit")
        return r.ok ? .ok("\(clean) beendet.") : .error(r.error)
    }

    private func pmset(_ arg: String, ok: String) async -> ToolOutcome {
        let r = await runProcess("/usr/bin/pmset", [arg])
        return r.code == 0 ? .ok(ok) : .error(r.err.isEmpty ? "pmset fehlgeschlagen" : r.err)
    }

    private func lockScreen() async -> ToolOutcome {
        let r = await osa("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
        return r.ok ? .ok("Bildschirm gesperrt.") : .error(r.error)
    }

    private func emptyTrash() async -> ToolOutcome {
        let r = await osa("tell application \"Finder\" to empty trash")
        return r.ok ? .ok("Papierkorb geleert.") : .error(r.error)
    }

    private func runShortcut(_ name: String) async -> ToolOutcome {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return .error("Kein Kurzbefehl-Name.") }
        let r = await runProcess("/usr/bin/shortcuts", ["run", clean])
        if r.code == 0 { return .ok("Kurzbefehl '\(clean)' ausgeführt. \(r.out.prefix(200))") }
        return .error("Kurzbefehl '\(clean)' nicht gefunden oder fehlgeschlagen.")
    }

    private func runShell(_ command: String) async -> ToolOutcome {
        let clean = command.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return .error("Kein Befehl.") }
        let r = await runProcess("/bin/zsh", ["-c", clean])
        let combined = (r.out + (r.err.isEmpty ? "" : "\n[stderr] " + r.err)).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = combined.isEmpty ? "(keine Ausgabe)" : String(combined.prefix(4000))
        return r.code == 0 ? .ok(body) : .error("Exit \(r.code): \(body)")
    }

    // MARK: - Process / AppleScript helpers (run off the main thread)

    private func runProcess(_ launch: String, _ args: [String], stdin: String? = nil) async -> (out: String, err: String, code: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launch)
                p.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                var inPipe: Pipe?
                if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe }
                do { try p.run() } catch {
                    cont.resume(returning: ("", error.localizedDescription, -1)); return
                }
                if let stdin, let inPipe {
                    inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                    inPipe.fileHandleForWriting.closeFile()
                }
                let o = outPipe.fileHandleForReading.readDataToEndOfFile()
                let e = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (String(data: o, encoding: .utf8) ?? "",
                                        String(data: e, encoding: .utf8) ?? "",
                                        p.terminationStatus))
            }
        }
    }

    private func osa(_ source: String) async -> (ok: Bool, value: String, error: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var errDict: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: (false, "", "Script konnte nicht erstellt werden")); return
                }
                let result = script.executeAndReturnError(&errDict)
                if let errDict {
                    let msg = (errDict["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript-Fehler"
                    cont.resume(returning: (false, "", msg))
                } else {
                    cont.resume(returning: (true, result.stringValue ?? "", ""))
                }
            }
        }
    }

    /// AppleScript-safe double-quoted literal.
    private func literal(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
                       .replacingOccurrences(of: "\n", with: " ")
                       .replacingOccurrences(of: "\r", with: " ")
        return "\"\(cleaned)\""
    }

    private func formatMinutes(_ m: Double) -> String {
        if m < 1 { return "\(Int(m * 60)) Sekunden" }
        let whole = Int(m)
        return m == Double(whole) ? "\(whole) Minuten" : String(format: "%.1f Minuten", m)
    }
}

import Foundation
import AppKit
import Combine

/// Minimal Claude (Anthropic) chat client over raw HTTP — no SDK needed.
/// The API key is read from ~/.config/DynamicIsland/anthropic_key.txt
/// (or pasted from the clipboard and saved there).
final class ClaudeService: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: String      // "user" | "assistant"
        var text: String
    }

    @Published var turns: [Turn] = []
    @Published var isLoading = false
    @Published var hasKey = false
    @Published var errorText: String?

    private let systemPrompt = """
    Du bist ein hilfreicher, knapper Assistent in einer Dynamic Island auf dem Mac. \
    Antworte kurz und präzise, meist in 1–4 Sätzen, in der Sprache der Frage.

    Du kannst die Island steuern, indem du Befehle in doppelten spitzen Klammern ausgibst \
    (sie werden dem Nutzer nicht angezeigt). Verfügbare Befehle:
    <<tab:NAME>> öffnet einen Tab (musik, claude, spiegel, aufnahme, ablage, timer, todos, kalender)
    <<timer:MINUTEN>> startet einen Countdown
    <<play>> <<pause>> <<next>> <<previous>> steuern die Musik
    <<shuffle:on>> / <<shuffle:off>> / <<repeat:on>> / <<repeat:off>>
    <<accent:FARBE>> (pink, blue, purple, indigo, teal, green, orange, red)
    <<todo:add:TEXT>> fügt eine Aufgabe hinzu, <<todo:done:TEXT>> hakt sie ab
    Nutze Befehle NUR, wenn der Nutzer wirklich eine Aktion will, und schreibe eine kurze \
    Bestätigung dazu (z.B. "Timer läuft 5 Minuten."). Bei reinen Wissensfragen keine Befehle.
    """

    /// Called for each control command Claude emits (without the « » markers).
    var onCommand: ((String) -> Void)?

    private var apiKey: String?
    private let settings = AppSettings.shared

    /// True only when the Anthropic provider is selected but no key is set.
    var needsSetup: Bool { settings.aiProvider == .anthropic && !hasKey }

    private var keyURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/DynamicIsland", isDirectory: true)
        return dir.appendingPathComponent("anthropic_key.txt")
    }

    init() { loadKey() }

    func loadKey() {
        if let data = try? Data(contentsOf: keyURL),
           let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            apiKey = key
            hasKey = true
        } else {
            hasKey = false
        }
    }

    /// Reads an API key from the clipboard and stores it.
    func pasteKeyFromClipboard() {
        guard let key = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            errorText = "Zwischenablage leer"
            return
        }
        saveKey(key)
    }

    func saveKey(_ key: String) {
        let dir = keyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try key.write(to: keyURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            apiKey = key
            hasKey = true
            errorText = nil
        } catch {
            errorText = "Konnte Schlüssel nicht speichern"
        }
    }

    func clear() {
        turns.removeAll()
        errorText = nil
    }

    func ask(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }
        turns.append(Turn(role: "user", text: trimmed))
        isLoading = true
        errorText = nil

        let history = Array(turns.suffix(10))
        switch settings.aiProvider {
        case .anthropic: sendAnthropic(history)
        case .lmStudio:  sendLMStudio(history)
        }
    }

    private enum Parsed { case success(String), failure(String) }

    private func sendAnthropic(_ history: [Turn]) {
        guard let apiKey else { finish(error: "Kein API-Schlüssel"); return }
        let messages = history.map { ["role": $0.role, "content": $0.text] }
        let body: [String: Any] = [
            "model": settings.anthropicModel, "max_tokens": 1024, "system": systemPrompt, "messages": messages,
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        run(req) { json in
            if let err = json["error"] as? [String: Any], let m = err["message"] as? String { return .failure(m) }
            let blocks = json["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
            return text.isEmpty ? .failure("Leere Antwort") : .success(text)
        }
    }

    private func sendLMStudio(_ history: [Turn]) {
        guard let url = URL(string: settings.lmStudioURL) else { finish(error: "Ungültige LM-Studio-URL"); return }
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        messages += history.map { ["role": $0.role, "content": $0.text] }
        let body: [String: Any] = [
            "model": settings.lmStudioModel, "messages": messages, "max_tokens": 1024, "stream": false,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        run(req) { json in
            if let err = json["error"] {
                let m = (err as? [String: Any])?["message"] as? String ?? "\(err)"
                return .failure(m)
            }
            let choices = json["choices"] as? [[String: Any]] ?? []
            let text = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            return text.isEmpty ? .failure("Leere Antwort") : .success(text)
        }
    }

    private func run(_ request: URLRequest, parse: @escaping ([String: Any]) -> Parsed) {
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                let extra = self.settings.aiProvider == .lmStudio
                    ? "LM Studio nicht erreichbar – läuft der lokale Server? "
                    : ""
                self.finish(error: extra + error.localizedDescription)
                return
            }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finish(error: "Ungültige Antwort"); return
            }
            switch parse(json) {
            case .success(let text): self.finish(text: text)
            case .failure(let msg):  self.finish(error: msg)
            }
        }.resume()
    }

    private func finish(text: String? = nil, error: String? = nil) {
        DispatchQueue.main.async {
            self.isLoading = false
            if let error { self.errorText = error }
            if let text {
                let (clean, commands) = Self.extractCommands(text)
                commands.forEach { self.onCommand?($0) }
                let display = clean.isEmpty ? (commands.isEmpty ? text : "Erledigt.") : clean
                self.turns.append(Turn(role: "assistant", text: display))
            }
        }
    }

    /// Pulls `<<command>>` tokens out of the text, returning the cleaned text and the commands.
    static func extractCommands(_ text: String) -> (clean: String, commands: [String]) {
        var commands: [String] = []
        var clean = text
        while let open = clean.range(of: "<<"),
              let close = clean.range(of: ">>", range: open.upperBound..<clean.endIndex) {
            commands.append(String(clean[open.upperBound..<close.lowerBound]))
            clean.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }
        return (clean.trimmingCharacters(in: .whitespacesAndNewlines), commands)
    }
}

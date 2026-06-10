import Foundation

// MARK: - JSON value (keeps Turn/ContentBlock Equatable without [String: Any])

/// A minimal JSON value so tool inputs can live in Equatable model types.
enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(_ any: Any) {
        switch any {
        case let n as NSNumber:
            // Distinguish a JSON boolean (CFBoolean) from a numeric NSNumber.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String:        self = .string(s)
        case let a as [Any]:         self = .array(a.map(JSONValue.init))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
        case is NSNull:              self = .null
        default:                     self = .null
        }
    }

    /// Back to a Foundation object for JSONSerialization.
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b):   return b
        case .null:          return NSNull()
        case .array(let a):  return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "on", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? { doubleValue.map { Int($0.rounded()) } }
}

// MARK: - Content blocks (text / tool_use / tool_result)

enum ContentBlock: Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseID: String, content: String, isError: Bool)

    /// Anthropic Messages API wire form.
    var wire: [String: Any] {
        switch self {
        case .text(let t):
            return ["type": "text", "text": t]
        case .toolUse(let id, let name, let input):
            return ["type": "tool_use", "id": id, "name": name, "input": input.mapValues { $0.anyValue }]
        case .toolResult(let id, let content, let isError):
            return ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]
        }
    }
}

// MARK: - Tool outcome

struct ToolOutcome: Equatable {
    let message: String      // → tool_result content (model- and human-readable)
    let isError: Bool
    static func ok(_ m: String) -> ToolOutcome { .init(message: m, isError: false) }
    static func error(_ m: String) -> ToolOutcome { .init(message: m, isError: true) }
}

// MARK: - Tool registry

enum Danger { case safe, confirm }

struct ToolSpec {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let danger: Danger
}

/// The catalog of tools the assistant can call. `danger` is local-only (never sent
/// to the API); `confirm` tools require the user to tap Allow before they run.
final class ToolRegistry {
    static let shared = ToolRegistry()

    let tools: [ToolSpec]

    func tool(named name: String) -> ToolSpec? { tools.first { $0.name == name } }

    /// The subset to advertise. Mac tools are hidden when the user disables control.
    func tools(macControl: Bool) -> [ToolSpec] {
        macControl ? tools : tools.filter { Self.islandToolNames.contains($0.name) }
    }

    /// Anthropic `tools` array.
    func anthropicTools(macControl: Bool) -> [[String: Any]] {
        tools(macControl: macControl).map {
            ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema]
        }
    }

    /// OpenAI / LM Studio `tools` array.
    func openAITools(macControl: Bool) -> [[String: Any]] {
        tools(macControl: macControl).map {
            ["type": "function",
             "function": ["name": $0.name, "description": $0.description, "parameters": $0.inputSchema]]
        }
    }

    static let islandToolNames: Set<String> = [
        "start_timer", "open_tab", "set_accent", "add_todo", "mark_todo_done",
        "media_play", "media_pause", "media_next", "media_previous", "media_shuffle", "media_repeat",
    ]

    private init() {
        // Schema helpers.
        func obj(_ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var s: [String: Any] = ["type": "object", "properties": props]
            if !required.isEmpty { s["required"] = required }
            return s
        }
        let str: [String: Any] = ["type": "string"]
        func strEnum(_ cases: [String]) -> [String: Any] { ["type": "string", "enum": cases] }
        let boolP: [String: Any] = ["type": "boolean"]

        tools = [
            // ── Island (safe) ───────────────────────────────────────────────
            ToolSpec(name: "start_timer", description: "Startet einen Countdown-Timer in der Island.",
                     inputSchema: obj(["minutes": ["type": "number", "description": "Dauer in Minuten"]], required: ["minutes"]),
                     danger: .safe),
            ToolSpec(name: "open_tab", description: "Öffnet einen Tab in der Island.",
                     inputSchema: obj(["tab": strEnum(["musik", "claude", "spiegel", "aufnahme", "ablage", "timer", "todos", "kalender"])], required: ["tab"]),
                     danger: .safe),
            ToolSpec(name: "set_accent", description: "Setzt die Akzentfarbe der Island.",
                     inputSchema: obj(["color": strEnum(["pink", "blue", "purple", "indigo", "teal", "green", "orange", "red"])], required: ["color"]),
                     danger: .safe),
            ToolSpec(name: "add_todo", description: "Fügt eine Aufgabe zur Todo-Liste hinzu.",
                     inputSchema: obj(["text": str], required: ["text"]), danger: .safe),
            ToolSpec(name: "mark_todo_done", description: "Hakt eine Aufgabe per Textmatch ab.",
                     inputSchema: obj(["text": str], required: ["text"]), danger: .safe),
            ToolSpec(name: "media_play", description: "Setzt die Wiedergabe fort.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "media_pause", description: "Pausiert die Wiedergabe.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "media_next", description: "Spielt den nächsten Titel.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "media_previous", description: "Spielt den vorherigen Titel.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "media_shuffle", description: "Schaltet die Zufallswiedergabe ein/aus.",
                     inputSchema: obj(["on": boolP], required: ["on"]), danger: .safe),
            ToolSpec(name: "media_repeat", description: "Setzt den Wiederholungsmodus (off, one, all).",
                     inputSchema: obj(["mode": strEnum(["off", "one", "all"])], required: ["mode"]), danger: .safe),

            // ── Mac read (safe) ─────────────────────────────────────────────
            ToolSpec(name: "get_battery_status", description: "Fragt den Akkustand des Macs ab.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "get_volume", description: "Fragt die aktuelle Lautstärke ab.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "get_now_playing", description: "Gibt den aktuell laufenden Titel zurück.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "list_running_apps", description: "Listet die sichtbar laufenden Apps auf.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "get_frontmost_app", description: "Gibt die Vordergrund-App zurück.", inputSchema: obj(), danger: .safe),
            ToolSpec(name: "get_clipboard", description: "Liest den Text der Zwischenablage (kann sensibel sein).", inputSchema: obj(), danger: .safe),

            // ── Mac mutate (safe, reversible) ───────────────────────────────
            ToolSpec(name: "set_volume", description: "Setzt die System-Lautstärke in Prozent (0–100).",
                     inputSchema: obj(["percent": ["type": "integer", "minimum": 0, "maximum": 100]], required: ["percent"]), danger: .safe),
            ToolSpec(name: "set_brightness", description: "Setzt die Display-Helligkeit in Prozent (0–100). Braucht einmalig einen Kurzbefehl 'Set Brightness'.",
                     inputSchema: obj(["percent": ["type": "integer", "minimum": 0, "maximum": 100]], required: ["percent"]), danger: .safe),
            ToolSpec(name: "set_do_not_disturb", description: "Schaltet 'Nicht stören' ein/aus. Braucht Kurzbefehle 'DND On'/'DND Off'.",
                     inputSchema: obj(["on": boolP], required: ["on"]), danger: .safe),
            ToolSpec(name: "set_appearance", description: "Schaltet zwischen Hell und Dunkel (dark = true für Dunkelmodus).",
                     inputSchema: obj(["dark": boolP], required: ["dark"]), danger: .safe),
            ToolSpec(name: "open_app", description: "Öffnet/aktiviert eine App per Name, z. B. 'Safari', 'Notes'.",
                     inputSchema: obj(["name": str], required: ["name"]), danger: .safe),
            ToolSpec(name: "open_url", description: "Öffnet eine Webseite im Standardbrowser (nur http/https).",
                     inputSchema: obj(["url": str], required: ["url"]), danger: .safe),
            ToolSpec(name: "web_search", description: "Öffnet eine Web-Suche im Browser.",
                     inputSchema: obj(["query": str, "engine": strEnum(["google", "youtube", "maps", "amazon", "duckduckgo"])], required: ["query"]), danger: .safe),
            ToolSpec(name: "set_clipboard", description: "Kopiert Text in die Zwischenablage.",
                     inputSchema: obj(["text": str], required: ["text"]), danger: .safe),
            ToolSpec(name: "send_notification", description: "Zeigt eine macOS-Mitteilung an.",
                     inputSchema: obj(["title": str, "body": str], required: ["title"]), danger: .safe),
            ToolSpec(name: "take_screenshot", description: "Nimmt lautlos einen Screenshot auf und speichert ihn (Standard: Schreibtisch).",
                     inputSchema: obj(["path": ["type": "string", "description": "Absoluter Zielpfad, optional"]]), danger: .safe),

            // ── Mac mutate (confirm, high impact) ───────────────────────────
            ToolSpec(name: "quit_app", description: "Beendet eine App (ungesicherte Arbeit kann verloren gehen).",
                     inputSchema: obj(["name": str], required: ["name"]), danger: .confirm),
            ToolSpec(name: "sleep_display", description: "Schaltet den Bildschirm in den Ruhezustand.", inputSchema: obj(), danger: .confirm),
            ToolSpec(name: "sleep_system", description: "Versetzt den Mac in den Ruhezustand.", inputSchema: obj(), danger: .confirm),
            ToolSpec(name: "lock_screen", description: "Sperrt den Bildschirm.", inputSchema: obj(), danger: .confirm),
            ToolSpec(name: "empty_trash", description: "Leert den Papierkorb endgültig (unwiderruflich).", inputSchema: obj(), danger: .confirm),
            ToolSpec(name: "run_shortcut", description: "Führt einen benannten Kurzbefehl (Shortcut) aus.",
                     inputSchema: obj(["name": str], required: ["name"]), danger: .confirm),
            ToolSpec(name: "run_shell", description: "Führt einen Shell-Befehl (zsh) aus. Sehr mächtig — der Befehl wird dem Nutzer zur Bestätigung gezeigt.",
                     inputSchema: obj(["command": str], required: ["command"]), danger: .confirm),
        ]
    }
}

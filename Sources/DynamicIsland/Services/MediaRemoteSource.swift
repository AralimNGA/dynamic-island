import AppKit

/// Systemweites „Now Playing“ über Apples privates MediaRemote – für jede App
/// (Spotify, Musik, Podcasts, Safari/Chrome-Videos, VLC …), inklusive Cover.
///
/// Seit macOS 15.4 dürfen nur noch Apple-Prozesse MediaRemote lesen. Der
/// mediaremote-adapter (Vendor/, BSD-3) umgeht das, indem `/usr/bin/perl`
/// (Bundle-ID com.apple.perl) das Adapter-Framework lädt und Änderungen als
/// JSON-Zeilen streamt. Meldet MediaRemote nichts (oder ist der Weg gesperrt),
/// füllt MediaController die Lücke per AppleScript.
///
/// Threading: `stopped`, `generation`, `payload`, `process` … gehören der
/// seriellen `queue`. `isAvailable`, `runToken` und alle Callbacks leben auf Main.
final class MediaRemoteSource {
    struct Snapshot: Equatable {
        var bundleID = ""
        var title = ""
        var artist = ""
        var album = ""
        var playing = false
        var duration: Double = 0          // Sekunden
        var elapsed: Double = 0           // Sekunden zum Zeitpunkt `timestamp`
        var timestamp = Date()
        var rate: Double = 1
        var shuffle: Int?                 // 1 aus, 2 Alben, 3 Titel
        var repeatMode: Int?              // 1 aus, 2 Titel, 3 Playlist
        var artworkID = 0                 // ändert sich, wenn ein neues Cover kam (oder es wegfiel)

        /// Hochgerechnete aktuelle Position.
        func position(at now: Date = Date()) -> Double {
            guard playing else { return elapsed }
            let p = elapsed + now.timeIntervalSince(timestamp) * max(rate, 0)
            return duration > 0 ? min(duration, max(0, p)) : max(0, p)
        }
    }

    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3
        case nextTrack = 4, previousTrack = 5
        case skipBack15 = 12, skipForward15 = 13
    }

    /// Neuer Zustand (nil = nichts spielt), Cover (nur wenn ein neues kam), auf Main.
    var onUpdate: ((Snapshot?, NSImage?) -> Void)?
    /// Stream läuft (true) oder ist dauerhaft gescheitert (false), auf Main.
    var onAvailabilityChange: ((Bool) -> Void)?

    // --- nur auf Main ---
    private(set) var isAvailable = false
    /// Zählt jeden start()/stop() – Meldungen aus älteren Läufen werden verworfen.
    private var runToken = 0

    private let queue = DispatchQueue(label: "island.mediaremote", qos: .userInitiated)
    // --- ab hier nur auf `queue` ---
    private var process: Process?
    private var token = 0                // runToken des aktuellen Laufs (Kopie für die Queue)
    private var generation = 0           // pro gestartetem Prozess
    private var stopped = true
    private var failures = 0
    private var streamStart: Date?
    private var pendingRestart: DispatchWorkItem?
    private var buffer = Data()
    private var skippingLine = false
    private var payload: [String: Any] = [:]
    private var artworkCounter = 0

    /// Zeilen über dieser Grösse werden verworfen und ohne Cover neu abgeglichen.
    private static let maxLineBytes = 64_000_000

    // MARK: Pfade

    private struct Paths { let script: String; let framework: String }

    /// Im App-Bundle: Resources/mediaremote-adapter.pl + Frameworks/MediaRemoteAdapter.framework.
    /// Für Entwicklung: ISLAND_MR_DIR=<Ordner mit beidem>.
    private static var paths: Paths? {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["ISLAND_MR_DIR"] {
            let p = Paths(script: dir + "/mediaremote-adapter.pl", framework: dir + "/MediaRemoteAdapter.framework")
            return fm.fileExists(atPath: p.script) && fm.fileExists(atPath: p.framework) ? p : nil
        }
        guard let res = Bundle.main.resourceURL?.path,
              let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework").path
        else { return nil }
        let p = Paths(script: res + "/mediaremote-adapter.pl", framework: fw)
        return fm.fileExists(atPath: p.script) && fm.fileExists(atPath: p.framework) ? p : nil
    }

    // MARK: Start / Stop (auf Main aufrufen)

    /// Startet den Stream. Kein Vorab-`test`: der bräuchte ohne laufende
    /// Wiedergabe einen eigenen Test-Client. Verfügbar heisst: Stream läuft.
    /// Ein gesperrter Weg zeigt sich als wiederholter Abbruch (→ Aufgeben).
    func start() {
        runToken &+= 1
        isAvailable = false          // der nächste Erfolg soll den Callback sicher auslösen
        let tok = runToken
        queue.async { [weak self] in
            guard let self else { return }
            self.token = tok
            self.pendingRestart?.cancel()
            self.stopped = false
            self.failures = 0
            guard self.process == nil else { self.report(true); return }
            guard let paths = Self.paths else {
                Self.log("Adapter nicht im Bundle – AppleScript-Fallback")
                self.report(false)
                return
            }
            Self.killOrphanStreams(paths)
            self.startStream(paths)
        }
    }

    func stop(sync: Bool = false) {
        runToken &+= 1
        isAvailable = false          // ohne Callback – der Aufrufer weiss Bescheid
        let work = { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.generation &+= 1
            self.pendingRestart?.cancel()
            self.pendingRestart = nil
            self.process?.terminate()
            self.process = nil
            self.payload.removeAll()
        }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Aus `queue`: Verfügbarkeit auf Main melden (Meldungen alter Läufe verwerfen).
    private func report(_ ok: Bool) {
        let tok = token
        DispatchQueue.main.async { [weak self] in
            guard let self, tok == self.runToken, self.isAvailable != ok else { return }
            self.isAvailable = ok
            self.onAvailabilityChange?(ok)
        }
    }

    // MARK: Stream

    private func startStream(_ paths: Paths) {
        process?.terminate()
        generation &+= 1
        let gen = generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework, "stream", "--micros", "--debounce=60"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        buffer.removeAll()
        skippingLine = false
        payload.removeAll()

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }     // EOF
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                self.consume(data)
            }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async {
                guard let self, self.generation == gen else { return }
                self.streamEnded(paths, status: proc.terminationStatus)
            }
        }
        do {
            try p.run()
            process = p
            streamStart = Date()
            report(true)
            Self.log("Stream gestartet (pid \(p.processIdentifier))")
        } catch {
            Self.log("Stream-Start fehlgeschlagen: \(error)")
            process = nil
            report(false)
        }
    }

    /// Stream beendet (Absturz, Neustart von mediaremoted …) → mit Backoff neu starten.
    private func streamEnded(_ paths: Paths, status: Int32) {
        process = nil
        guard !stopped else { return }
        // Lief der Stream eine Weile, war es ein einzelner Aussetzer.
        if let s = streamStart, Date().timeIntervalSince(s) >= 30 { failures = 0 }
        failures += 1
        Self.log("Stream beendet (Status \(status)), Versuch \(failures)")
        payload.removeAll()
        let tok = token
        DispatchQueue.main.async { [weak self] in                   // keine Position weiterzählen
            guard let self, tok == self.runToken else { return }
            self.onUpdate?(nil, nil)
        }
        if failures >= 6 {
            // Dauerhaft kaputt (z. B. Apple hat den Weg gesperrt) → AppleScript übernimmt.
            report(false)
            return
        }
        let delay = min(30, pow(2, Double(failures)))
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.generation == gen, self.process == nil else { return }
            self.startStream(paths)
        }
        pendingRestart = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Parsen

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if skippingLine { skippingLine = false; continue }   // Rest einer verworfenen Zeile
            guard !line.isEmpty else { continue }
            handle(line)
        }
        if buffer.count > Self.maxLineBytes {
            // Unrealistisch grosse Zeile: verwerfen und ohne Cover neu abgleichen.
            buffer.removeAll()
            skippingLine = true
            resync()
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            resync()                   // kaputte Zeile → Diff-Stand unsicher
            return
        }
        guard (obj["type"] as? String) == "data",
              let incoming = obj["payload"] as? [String: Any] else { return }
        let diff = (obj["diff"] as? Bool) ?? false

        if diff {
            // Play/Pause kommt ohne neue Zeitwerte (die folgen entprellt später).
            // Position an „jetzt“ verankern, sonst springt der Balken.
            if incoming["playing"] != nil,
               incoming["elapsedTimeMicros"] == nil, incoming["timestampEpochMicros"] == nil,
               payload["elapsedTimeMicros"] != nil,
               let prev = snapshot(from: payload) {
                let now = Date()
                payload["elapsedTimeMicros"] = prev.position(at: now) * 1_000_000
                payload["timestampEpochMicros"] = now.timeIntervalSince1970 * 1_000_000
            }
            for (k, v) in incoming {
                if v is NSNull { payload.removeValue(forKey: k) } else { payload[k] = v }
            }
        } else {
            payload = incoming
        }

        var newArtwork: NSImage?
        if let b64 = incoming["artworkData"] as? String {
            newArtwork = Data(base64Encoded: b64).flatMap { NSImage(data: $0) }
            artworkCounter += 1
        } else if !diff || incoming["artworkData"] is NSNull {
            artworkCounter += 1          // Cover entfernt bzw. neues Medium ohne Cover
        }
        payload.removeValue(forKey: "artworkData")   // nicht im Speicher mitschleppen

        emit(artwork: newArtwork)
    }

    private func emit(artwork: NSImage?) {
        let snap = payload.isEmpty ? nil : snapshot(from: payload)
        let tok = token
        DispatchQueue.main.async { [weak self] in
            guard let self, tok == self.runToken else { return }   // Meldung aus einem gestoppten Lauf
            self.onUpdate?(snap, artwork)
        }
    }

    /// Einmalig den vollen Stand ohne Cover holen und als Voll-Update übernehmen.
    private func resync() {
        guard let paths = Self.paths else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework, "get", "--micros", "--no-artwork"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        payload = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        artworkCounter += 1
        emit(artwork: nil)
    }

    private func snapshot(from p: [String: Any]) -> Snapshot? {
        guard let title = p["title"] as? String, !title.isEmpty else { return nil }
        var s = Snapshot()
        s.bundleID = (p["parentApplicationBundleIdentifier"] as? String)
            ?? (p["bundleIdentifier"] as? String) ?? ""
        s.title = title
        s.artist = p["artist"] as? String ?? ""
        s.album = p["album"] as? String ?? ""
        s.playing = p["playing"] as? Bool ?? false
        s.duration = Self.number(p["durationMicros"]) / 1_000_000
        s.elapsed = Self.number(p["elapsedTimeMicros"]) / 1_000_000
        let ts = Self.number(p["timestampEpochMicros"])
        s.timestamp = ts > 0 ? Date(timeIntervalSince1970: ts / 1_000_000) : Date()
        s.rate = p["playbackRate"] != nil ? Self.number(p["playbackRate"]) : 1
        if s.playing && s.rate == 0 { s.rate = 1 }
        s.shuffle = (p["shuffleMode"] as? NSNumber)?.intValue
        s.repeatMode = (p["repeatMode"] as? NSNumber)?.intValue
        s.artworkID = artworkCounter
        return s
    }

    private static func number(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    // MARK: Befehle

    func send(_ command: Command) { runAsync(["send", String(command.rawValue)]) }

    func seek(to seconds: Double) {
        runAsync(["seek", String(Int64(max(0, seconds) * 1_000_000))])
    }

    /// 1 = aus, 2 = Titel, 3 = Playlist
    func setRepeat(_ mode: Int) { runAsync(["repeat", String(mode)]) }

    /// Kurze Befehlsprozesse – eigene Queue, damit sie den Stream nie aufhalten.
    private static let commandQueue = DispatchQueue(label: "island.mediaremote.cmd", qos: .userInitiated)

    private func runAsync(_ args: [String]) {
        Self.commandQueue.async {
            guard let paths = Self.paths else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [paths.script, paths.framework] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()          // Reihenfolge der Befehle wahren, keine Zombies
        }
    }

    /// Streams einer abgestürzten/abgeschossenen früheren Instanz beenden.
    private static func killOrphanStreams(_ paths: Paths) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", NSRegularExpression.escapedPattern(for: paths.script) + " "
                       + NSRegularExpression.escapedPattern(for: paths.framework) + " stream"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    private static func log(_ s: String) { MediaController.log("‹mr› " + s) }
}

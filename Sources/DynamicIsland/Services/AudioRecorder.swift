import AVFoundation
import AppKit
import Combine

/// Microphone recorder for the "Aufnahme" tab. Saves m4a files to
/// ~/Music/DynamicIsland Aufnahmen and plays them back.
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var recordings: [URL] = []
    @Published var permissionDenied = false
    @Published var playingURL: URL?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var startDate: Date?

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return f
    }()

    var folder: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/DynamicIsland Aufnahmen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override init() {
        super.init()
        refreshList()
    }

    func refreshList() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recordings = urls
            .filter { $0.pathExtension.lowercased() == "m4a" }
            .sorted { a, b in modDate(a) > modDate(b) }
    }

    private func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func toggle() { isRecording ? stop() : requestAndStart() }

    private func requestAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.start() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func start() {
        let name = "Aufnahme \(Self.nameFormatter.string(from: Date())).m4a"
        let url = folder.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            guard rec.record() else { permissionDenied = true; return }
            recorder = rec
            isRecording = true
            startDate = Date()
            elapsed = 0
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } catch {
            permissionDenied = true
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        ticker?.invalidate(); ticker = nil
        isRecording = false
        startDate = nil
        refreshList()
    }

    func play(_ url: URL) {
        if playingURL == url {
            player?.stop(); player = nil; playingURL = nil
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingURL = url
        } catch {}
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func delete(_ url: URL) {
        if playingURL == url { player?.stop(); player = nil; playingURL = nil }
        try? FileManager.default.removeItem(at: url)
        refreshList()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playingURL = nil }
    }
}

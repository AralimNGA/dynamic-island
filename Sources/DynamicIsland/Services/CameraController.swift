import AVFoundation
import AppKit
import Combine

/// Front-camera capture for the mirror feature. Starts only while the mirror tab
/// is visible (privacy) and mirrors the preview like a real mirror.
final class CameraController: ObservableObject {
    enum State { case idle, authorized, denied }

    @Published var state: State = .idle
    let session = AVCaptureSession()

    private var configured = false
    private let queue = DispatchQueue(label: "island.camera")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = .authorized
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.state = granted ? .authorized : .denied
                    if granted { self?.run() }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                    ?? AVCaptureDevice.default(for: .video)
                if let device, let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                self.session.commitConfiguration()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
}

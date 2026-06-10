import SwiftUI
import AVFoundation

/// AppKit-backed live camera preview, mirrored like a real mirror.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyMirror()
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session { nsView.previewLayer.session = session }
        nsView.applyMirror()
    }
}

final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyMirror() {
        if let conn = previewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
    }
}

/// The "Spiegel" tab.
struct MirrorView: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        ZStack {
            switch camera.state {
            case .authorized:
                CameraPreview(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )
            case .denied:
                deniedView
            case .idle:
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var deniedView: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.4))
            Text("Kein Kamerazugriff")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Einstellungen öffnen")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }
}

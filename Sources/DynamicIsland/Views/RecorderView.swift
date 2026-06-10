import SwiftUI

/// The "Aufnahme" tab — record mic audio, play back, drag out, reveal, delete.
struct RecorderView: View {
    @ObservedObject var rec: AudioRecorder

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { rec.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(rec.isRecording ? Color.red : Color.white.opacity(0.12))
                            .frame(width: 38, height: 38)
                        Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(rec.isRecording ? .white : .red)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)

                if rec.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(rec.elapsed.clockString)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("Aufnehmen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }

            if rec.permissionDenied {
                Text("Kein Mikrofonzugriff – in den Einstellungen erlauben")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if rec.recordings.isEmpty {
                Spacer()
                Text("Noch keine Aufnahmen")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(rec.recordings, id: \.self) { url in
                            row(url)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Button { rec.play(url) } label: {
                Image(systemName: rec.playingURL == url ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)

            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.05)))
        .onDrag { NSItemProvider(object: url as NSURL) }
        .contextMenu {
            Button("Im Finder zeigen") { rec.reveal(url) }
            Button("Löschen", role: .destructive) { rec.delete(url) }
        }
    }
}

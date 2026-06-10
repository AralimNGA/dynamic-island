import SwiftUI
import UniformTypeIdentifiers

/// The "Ablage" — drag files in to hold them, drag them back out, or reveal in Finder.
struct ShelfView: View {
    @ObservedObject var shelf: ShelfModel
    @ObservedObject var state: IslandState

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            fileChip(item)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                HStack(spacing: 10) {
                    Text("^[\(shelf.items.count) Datei](inflect: true)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button { sendViaAirDrop() } label: {
                        Label("AirDrop", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.blue.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                    Button { shelf.clear() } label: {
                        Text("Leeren").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTarget)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(state.dragActive ? 0.9 : 0.4))
            Text(state.dragActive ? "Loslassen zum Ablegen" : "Dateien hierher ziehen")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(.white.opacity(state.dragActive ? 0.6 : 0.18))
        )
    }

    private func fileChip(_ item: ShelfModel.Item) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 40, height: 40)
            Text(item.name)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(width: 52)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Im Finder zeigen") { shelf.revealInFinder(item) }
            Button("Entfernen", role: .destructive) { shelf.remove(item) }
        }
    }

    private var dropTarget: some View {
        Color.clear
            .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
                handleDrop(providers)
            }
    }

    private var dropBinding: Binding<Bool> {
        Binding(get: { state.dragActive }, set: { state.dragActive = $0 })
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        ShelfModel.loadURLs(from: providers) { urls in
            if !urls.isEmpty { shelf.add(urls: urls) }
        }
    }

    private func sendViaAirDrop() {
        let urls = shelf.items.map { $0.url }
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let service = NSSharingService(named: .sendViaAirDrop) {
            service.perform(withItems: urls)
        }
    }
}

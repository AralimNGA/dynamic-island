import AppKit
import Combine

/// A holding area ("Ablage") for files dragged onto the island — like AirDrop's tray.
final class ShelfModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let icon: NSImage
        var name: String { url.lastPathComponent }
    }

    @Published var items: [Item] = []

    func add(urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.url == url }) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            items.append(Item(url: url, icon: icon))
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    func revealInFinder(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Resolves file URLs from dropped item providers, then calls back on the main queue.
    @discardableResult
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
        return true
    }
}

import Foundation
import Combine

/// A tiny persistent to-do list.
final class TodoModel: ObservableObject {
    struct Item: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var done = false
    }

    @Published var items: [Item] { didSet { save() } }
    private let key = "todos"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([Item].self, from: data) {
            items = arr
        } else {
            items = []
        }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        items.insert(Item(text: t), at: 0)
    }

    func toggle(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].done.toggle() }
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clearDone() { items.removeAll { $0.done } }

    /// Marks the first open item whose text contains `text` (case-insensitive) as done.
    func markDone(matching text: String) {
        let needle = text.lowercased()
        if let i = items.firstIndex(where: { !$0.done && $0.text.lowercased().contains(needle) }) {
            items[i].done = true
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

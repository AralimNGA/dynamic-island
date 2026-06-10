import SwiftUI

/// The "To-Dos" tab.
struct TodoView: View {
    @ObservedObject var todo: TodoModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Neue Aufgabe …", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canAdd ? Color.accentColor : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }

            if todo.items.isEmpty {
                Spacer()
                Text("Keine Aufgaben")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(todo.items) { item in row(item) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var canAdd: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty }

    private func add() { todo.add(input); input = "" }

    private func row(_ item: TodoModel.Item) -> some View {
        HStack(spacing: 8) {
            Button { todo.toggle(item) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.done ? Color.accentColor : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Text(item.text)
                .font(.system(size: 12))
                .strikethrough(item.done, color: .white.opacity(0.5))
                .foregroundStyle(.white.opacity(item.done ? 0.4 : 0.9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.05)))
        .contextMenu {
            Button("Löschen", role: .destructive) { todo.remove(item) }
        }
    }
}

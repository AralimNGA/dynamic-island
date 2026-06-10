import SwiftUI

/// The "Claude" tab — a quick AI assistant right in the notch.
struct ClaudeView: View {
    @ObservedObject var claude: ClaudeService
    @ObservedObject private var settings = AppSettings.shared
    @State private var input = ""

    var body: some View {
        if claude.needsSetup {
            keyPrompt
        } else {
            conversation
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if claude.turns.isEmpty {
                            Text("Frag Claude etwas …")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 8)
                        }
                        ForEach(claude.turns) { bubble($0) }
                        if claude.isLoading {
                            HStack { ProgressView().controlSize(.small); Spacer() }
                        }
                        if let err = claude.errorText {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: claude.turns.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: claude.isLoading) { withAnimation { proxy.scrollTo("bottom") } }
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bubble(_ turn: ClaudeService.Turn) -> some View {
        let isUser = turn.role == "user"
        return HStack {
            if isUser { Spacer(minLength: 24) }
            Text(turn.text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.10))
                )
                .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 24) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Nachricht …", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.10)))
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(input.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? .white.opacity(0.25) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || claude.isLoading)
        }
    }

    private func send() {
        let text = input
        input = ""
        claude.ask(text)
    }

    // MARK: No-key prompt

    private var keyPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
            Text("Claude verbinden")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Kopiere deinen Anthropic API-Schlüssel, dann:")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button { claude.pasteKeyFromClipboard() } label: {
                Text("Schlüssel aus Zwischenablage einfügen")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            if let err = claude.errorText {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button {
                NotificationCenter.default.post(name: .openIslandSettings, object: nil)
            } label: {
                Text("… oder LM Studio (lokal & gratis) in den Einstellungen wählen")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .underline()
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}

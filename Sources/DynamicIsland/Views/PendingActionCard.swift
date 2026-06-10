import SwiftUI

/// Shown when the assistant wants to run a dangerous (confirm) tool. The agent
/// loop is parked until the user taps Erlauben or Ablehnen.
struct PendingActionCard: View {
    let action: ClaudeService.PendingAction
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            if !action.detail.isEmpty {
                Text(action.detail)
                    .font(.system(size: 10, design: action.toolName == "run_shell" ? .monospaced : .default))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(action: onDeny) {
                    Text("Ablehnen")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Button(action: onAllow) {
                    Text("Erlauben")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(.orange))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.orange.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

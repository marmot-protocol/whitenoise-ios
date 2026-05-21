import SwiftUI

/// Liquid-glass composer at the bottom of the conversation screen. Multi-line
/// growing text field + send button. Disabled while a send is in-flight.
struct ComposerBar: View {
    @Binding var draft: String
    let isSending: Bool
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit(triggerSend)

            Button(action: triggerSend) {
                Image(systemName: isSending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    .symbolEffect(.bounce, value: isSending)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.tap()
        onSend()
    }
}

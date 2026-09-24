import SwiftUI

struct ChatListLeaveConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var contentHeight: CGFloat?

    let count: Int
    let onConfirm: () async -> String?

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height.rounded(.up)
                } action: { height in
                    guard height > 0 else { return }
                    contentHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .presentationDetents([contentHeight.map { .height($0) } ?? .medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(isSubmitting)
        .task(id: isSubmitting) {
            guard isSubmitting else { return }
            let failure = await onConfirm()
            guard !Task.isCancelled else { return }
            errorMessage = failure
            isSubmitting = false
            if failure == nil { dismiss() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.plural("Leave %lld chats?", Int64(count)))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("You'll stop receiving new messages in these chats. Their history will stay on this device until you delete it.")
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("leaveChatError")
                }
            }
            VStack {
                WNButton(
                    title: LocalizedStringKey(L10n.plural("Leave %lld chats", Int64(count))),
                    emphasis: .destructive,
                    isLoading: isSubmitting
                ) {
                    guard !isSubmitting else { return }
                    errorMessage = nil
                    isSubmitting = true
                }
                .accessibilityLabel(isSubmitting ? L10n.string("Leaving…") : L10n.plural("Leave %lld chats", Int64(count)))
                WNButton(title: "Cancel", emphasis: .secondary) { dismiss() }
                    .disabled(isSubmitting)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

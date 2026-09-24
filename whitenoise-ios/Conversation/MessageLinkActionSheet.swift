import SwiftUI

struct MessageLinkActionSheet: View {
    let url: URL
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    @State private var contentHeight: CGFloat = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(MessageExternalLinkConfirmation.displayText(for: url))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                VStack(spacing: 0) {
                    Button(action: onOpen) {
                        MessageLinkActionRow(title: L10n.string("Open Link"), systemImage: "safari")
                    }
                    Divider()
                        .padding(.leading)
                    Button(action: onCopy) {
                        MessageLinkActionRow(title: L10n.string("Copy Link"), systemImage: "doc.on.doc")
                    }
                }
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: WNGroupedCardMetrics.cornerRadius, style: .continuous)
                )

                Button(action: onCancel) {
                    Text("Cancel")
                        .bold()
                        .frame(maxWidth: .infinity, minHeight: WNButton.Metrics.fallbackLabelMinHeight)
                        .contentShape(.rect)
                }
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: WNGroupedCardMetrics.cornerRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .padding()
            .padding(.top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
    }
}

private struct MessageLinkActionRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: WNButton.Metrics.fallbackLabelMinHeight, alignment: .leading)
            .padding(.horizontal)
            .contentShape(.rect)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            MessageLinkActionSheet(
                url: URL(string: "https://example.com/article?id=42") ?? URL(filePath: "/"),
                onOpen: {},
                onCopy: {},
                onCancel: {}
            )
        }
}

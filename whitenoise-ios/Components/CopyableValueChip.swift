import SwiftUI
import UIKit

/// Tap-to-copy value pill (npub, group id, donation address). The value stays
/// middle-truncated and monospaced; only the trailing glyph confirms the copy.
struct CopyableValueChip: View {
    nonisolated enum Feedback {
        static let resetDelay = Duration.seconds(2)

        static func symbolName(isCopied: Bool) -> String {
            isCopied ? "checkmark" : "doc.on.doc"
        }

        static func accessibilityLabel(isCopied: Bool, valueName: String) -> String {
            isCopied ? L10n.string("Copied") : L10n.formatted("Copy %@", valueName)
        }
    }

    let display: String
    let copyValue: String
    let valueName: String
    var fillsAvailableWidth = false

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(display)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                Image(systemName: Feedback.symbolName(isCopied: copied))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.default, value: copied)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            .background(Color(uiColor: .secondarySystemFill), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Feedback.accessibilityLabel(isCopied: copied, valueName: valueName))
        .accessibilityValue(display)
        .onDisappear(perform: resetFeedback)
    }

    private func copy() {
        UIPasteboard.general.string = copyValue
        Haptics.selection()
        copied = true
        AccessibilityNotification.Announcement(L10n.string("Copied")).post()

        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: Feedback.resetDelay)
            guard !Task.isCancelled else { return }
            copied = false
            resetTask = nil
        }
    }

    private func resetFeedback() {
        resetTask?.cancel()
        resetTask = nil
        copied = false
    }
}

#Preview("CopyableValueChip") {
    VStack(spacing: 24) {
        CopyableValueChip(
            display: "npub1exam…f4k2",
            copyValue: "npub1exampleexampleexamplef4k2",
            valueName: "npub"
        )

        CopyableValueChip(
            display: "npub1exam…f4k2",
            copyValue: "npub1exampleexampleexamplef4k2",
            valueName: "npub",
            fillsAvailableWidth: true
        )
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

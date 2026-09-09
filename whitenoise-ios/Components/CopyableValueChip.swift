import SwiftUI
import UIKit

/// Tap-to-copy value pill (npub, group id, donation address). Shows a
/// transient copied state; the value stays middle-truncated and monospaced.
struct CopyableValueChip: View {
    let display: String
    let copyValue: String
    let copiedToastTitle: String
    var fillsAvailableWidth = false

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(copied ? L10n.string("Copied") : display)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            .background(Color(uiColor: .secondarySystemFill), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Copy %@", copiedToastTitle))
    }

    private func copy() {
        UIPasteboard.general.string = copyValue
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { copied = false }
        }
    }
}

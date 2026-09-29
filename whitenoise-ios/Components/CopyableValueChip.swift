import SwiftUI

/// Tap-to-copy value pill (npub, group id, donation address). The value stays
/// middle-truncated and monospaced; only the trailing glyph confirms the copy.
struct CopyableValueChip: View {
    let display: String
    let copyValue: String
    let valueName: String
    var fillsAvailableWidth = false

    var body: some View {
        WNCopyButton(value: copyValue, accessibilityTitle: L10n.formatted("Copy %@", valueName)) { copied in
            HStack(spacing: 6) {
                Text(display)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                WNCopyIcon(copied: copied)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .animation(.default, value: copied)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, minHeight: 44)
            .compatibleInputCapsuleChrome()
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(display)
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

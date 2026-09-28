import SwiftUI

struct CopyableValueRow: View {
    let title: String.LocalizationValue
    let value: String
    var display: String?

    var body: some View {
        WNCopyButton(value: value, accessibilityTitle: L10n.formatted("Copy %@", L10n.string(title))) { justCopied in
            LabeledContent {
                HStack(spacing: 8) {
                    Text(justCopied ? L10n.string("Copied") : display ?? value)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(justCopied ? Color.primary : Color.secondary)
                    WNCopyIcon(copied: justCopied)
                        .font(.caption)
                        .foregroundStyle(Color.primary)
                }
                .contentShape(.rect)
            } label: {
                Text(L10n.string(title))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("CopyableValueRow") {
    Form {
        CopyableValueRow(
            title: "Hex",
            value: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
            display: "3bf0c63f…fa459d"
        )
        CopyableValueRow(title: "npub", value: "npub1example")
    }
}

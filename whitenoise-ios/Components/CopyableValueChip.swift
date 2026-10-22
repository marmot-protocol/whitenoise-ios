import SwiftUI

/// Tap-to-copy value pill (npub, group id, donation address). The value stays
/// middle-truncated and monospaced; only the trailing glyph confirms the copy.
struct CopyableValueChip: View {
    let display: String
    let copyValue: String
    let valueName: String
    var fillsAvailableWidth = false
    var compact = false
    var usesFilledStyle = false

    var body: some View {
        WNCopyButton(value: copyValue, accessibilityTitle: L10n.formatted("Copy %@", valueName)) { copied in
            if usesFilledStyle {
                HStack {
                    Text(display)
                        .font(.subheadline.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    WNCopyIcon(copied: copied)
                        .font(.caption2.weight(.medium))
                        .frame(width: 14, height: 14)
                        .animation(.default, value: copied)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
                .background(Color(uiColor: .secondarySystemFill), in: .capsule)
                // Expand the hit area without changing the prototype pill's layout.
                .contentShape(Rectangle().inset(by: -8))
            } else {
                HStack(spacing: 6) {
                    Text(display)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(compact ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                    WNCopyIcon(copied: copied)
                        .font(compact ? .caption2.weight(.medium) : .body.weight(.medium))
                        .foregroundStyle(compact ? .secondary : .primary)
                        .frame(width: compact ? 14 : nil, height: compact ? 14 : nil)
                        .animation(.default, value: copied)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, minHeight: compact ? nil : 44)
                .modifier(CopyableValueSurface(compact: compact))
                .frame(minHeight: 44)
                .contentShape(.capsule)
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(display)
    }
}

private struct CopyableValueSurface: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.background(Color(uiColor: .secondarySystemFill), in: Capsule())
        } else {
            content.compatibleInputCapsuleChrome()
        }
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

import SwiftUI

nonisolated enum LocalizedNumberLabel {
    static func decimal(_ value: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%llu", locale: locale, value)
    }
}

/// Compact unread indicator shared by chat-list and profile rows. A manual
/// unread reminder with no unread messages renders as a dot; positive counts
/// render in a capsule capped at "99+".
struct UnreadCountBadge: View {
    nonisolated enum Presentation: Equatable {
        case dot
        case count(String)
    }

    @Environment(\.colorScheme) private var colorScheme

    let count: UInt64

    @ViewBuilder
    var body: some View {
        switch Self.presentation(for: count) {
        case .dot:
            Circle()
                .fill(WNBadge.Metrics.accent(for: colorScheme))
                .frame(
                    width: WNBadge.Metrics.dotDiameter,
                    height: WNBadge.Metrics.dotDiameter
                )
                .accessibilityLabel(L10n.string("Unread"))
        case .count(let label):
            WNBadge(text: label)
                .accessibilityLabel(L10n.plural("%llu unread messages", count))
        }
    }

    static func presentation(
        for count: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> Presentation {
        count == 0 ? .dot : .count(label(for: count, locale: locale))
    }

    /// Compact count label, capped at "99+" so the capsule keeps a small,
    /// fixed width no matter how many messages are unread.
    static func label(for count: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        if count > 99 {
            return L10n.formatted(
                "%@+",
                arguments: [LocalizedNumberLabel.decimal(99, locale: locale)],
                locale: locale
            )
        }
        return LocalizedNumberLabel.decimal(count, locale: locale)
    }
}

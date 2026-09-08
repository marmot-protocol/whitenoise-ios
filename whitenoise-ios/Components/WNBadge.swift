import SwiftUI

/// The app's small capsule marker for the trailing edge of a row: a bold count
/// on the monochrome accent, or a muted word naming a row's state. Shared so
/// counts and status pills keep one shape wherever a row needs one.
struct WNBadge: View {
    /// `prominent` is a count that should pull the eye; `neutral` is a state
    /// label that should not compete with the row's own text.
    nonisolated enum Emphasis: Equatable {
        case prominent
        case neutral
    }

    nonisolated enum Metrics {
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 2
        static let dotDiameter: CGFloat = 10

        /// The badge rides the same monochrome accent as `WNButton`, not the
        /// asset accent colour, so it stays black-on-white and white-on-black.
        static func accent(for colorScheme: ColorScheme) -> Color {
            WNButton.Metrics.accent(for: colorScheme)
        }

        static func fontWeight(for emphasis: Emphasis) -> Font.Weight {
            emphasis == .prominent ? .bold : .semibold
        }

        /// Only prominent badges carry counts, whose digits should not jitter
        /// as the number changes.
        static func usesMonospacedDigits(_ emphasis: Emphasis) -> Bool {
            emphasis == .prominent
        }

        static func background(
            for emphasis: Emphasis,
            colorScheme: ColorScheme
        ) -> Color {
            switch emphasis {
            case .prominent:
                accent(for: colorScheme)
            case .neutral:
                Color(uiColor: .systemGray5)
            }
        }

        static func foreground(for emphasis: Emphasis) -> AnyShapeStyle {
            switch emphasis {
            case .prominent:
                AnyShapeStyle(Color(uiColor: .systemBackground))
            case .neutral:
                AnyShapeStyle(.secondary)
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    let text: String
    var emphasis = Emphasis.prominent

    var body: some View {
        label
            .foregroundStyle(Metrics.foreground(for: emphasis))
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .background(
                Capsule().fill(
                    Metrics.background(for: emphasis, colorScheme: colorScheme)
                )
            )
    }

    private var label: Text {
        let base = Text(text)
            .font(.caption2.weight(Metrics.fontWeight(for: emphasis)))
        return Metrics.usesMonospacedDigits(emphasis) ? base.monospacedDigit() : base
    }
}

#Preview("WNBadge — Light") {
    VStack(spacing: 16) {
        WNBadge(text: "1")
        WNBadge(text: "99+")
        WNBadge(text: "Signed out", emphasis: .neutral)
        WNBadge(text: "Read-only", emphasis: .neutral)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
}

#Preview("WNBadge — Dark") {
    VStack(spacing: 16) {
        WNBadge(text: "1")
        WNBadge(text: "99+")
        WNBadge(text: "Signed out", emphasis: .neutral)
        WNBadge(text: "Read-only", emphasis: .neutral)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .preferredColorScheme(.dark)
}

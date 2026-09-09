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

    nonisolated enum Content: Equatable {
        case text(String)
        case symbol(String)
    }

    nonisolated enum Metrics {
        static let verticalPadding: CGFloat = 2
        static let dotDiameter: CGFloat = 10
        static let minimumHeight: CGFloat = 20

        static func horizontalPadding(for content: Content) -> CGFloat {
            switch content {
            case .text: 6
            case .symbol: 0
            }
        }

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
    @ScaledMetric(relativeTo: .caption2)
    private var minimumHeight = WNBadge.Metrics.minimumHeight

    let content: Content
    var emphasis = Emphasis.prominent

    init(text: String, emphasis: Emphasis = .prominent) {
        self.init(content: .text(text), emphasis: emphasis)
    }

    init(symbol: String, emphasis: Emphasis = .prominent) {
        self.init(content: .symbol(symbol), emphasis: emphasis)
    }

    init(content: Content, emphasis: Emphasis = .prominent) {
        self.content = content
        self.emphasis = emphasis
    }

    var body: some View {
        label
            .foregroundStyle(Metrics.foreground(for: emphasis))
            .padding(.horizontal, Metrics.horizontalPadding(for: content))
            .padding(.vertical, Metrics.verticalPadding)
            .frame(minWidth: minimumHeight, minHeight: minimumHeight)
            .background(
                Capsule().fill(
                    Metrics.background(for: emphasis, colorScheme: colorScheme)
                )
            )
    }

    private var label: Text {
        let base = glyph.font(.caption2.weight(Metrics.fontWeight(for: emphasis)))
        return Metrics.usesMonospacedDigits(emphasis) ? base.monospacedDigit() : base
    }

    private var glyph: Text {
        switch content {
        case .text(let value):
            Text(value)
        case .symbol(let name):
            Text(Image(systemName: name))
        }
    }
}

#Preview("WNBadge — Light") {
    VStack(spacing: 16) {
        WNBadge(text: "1")
        WNBadge(text: "99+")
        WNBadge(symbol: "plus")
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
        WNBadge(symbol: "plus")
        WNBadge(text: "Signed out", emphasis: .neutral)
        WNBadge(text: "Read-only", emphasis: .neutral)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .preferredColorScheme(.dark)
}

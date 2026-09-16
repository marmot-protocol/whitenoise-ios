import SwiftUI

/// Rounds a grouped section to the iOS 26 radius on the iOS 18 floor.
///
/// A system grouped section is drawn at ~26pt on iOS 26 but ~10pt before it,
/// so the same `List` reads noticeably squarer on the support floor than in
/// the reference design. Above the floor the system already draws it, so the
/// rows are left untouched; below it each row takes over its own corner and
/// the section composes back into one continuous card — which keeps every row
/// a real `List` cell, and with it the list's virtualization.
extension View {
    func wnGroupedCardRow(_ position: WNGroupedCardPosition) -> some View {
        modifier(WNGroupedCardRowModifier(position: position))
    }
}

nonisolated enum WNGroupedCardPosition: Equatable {
    case only
    case first
    case middle
    case last

    static func at(_ index: Int, of count: Int) -> Self {
        guard count > 1 else { return .only }
        switch index {
        case 0: return .first
        case count - 1: return .last
        default: return .middle
        }
    }

    var topRadius: CGFloat {
        self == .only || self == .first ? WNGroupedCardMetrics.cornerRadius : 0
    }

    var bottomRadius: CGFloat {
        self == .only || self == .last ? WNGroupedCardMetrics.cornerRadius : 0
    }
}

nonisolated enum WNGroupedCardMetrics {
    /// Measured from a grouped `List` section on iOS 26.
    static let cornerRadius: CGFloat = 26
}

private struct WNGroupedCardRowModifier: ViewModifier {
    let position: WNGroupedCardPosition

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.listRowBackground(
                UnevenRoundedRectangle(
                    topLeadingRadius: position.topRadius,
                    bottomLeadingRadius: position.bottomRadius,
                    bottomTrailingRadius: position.bottomRadius,
                    topTrailingRadius: position.topRadius,
                    style: .continuous
                )
                .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}

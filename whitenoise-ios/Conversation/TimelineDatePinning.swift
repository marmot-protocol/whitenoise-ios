import Foundation

nonisolated enum TimelineDatePinning {
    static let verticalPadding: CGFloat = 18

    enum Position: Equatable {
        case passed
        case approaching(offset: CGFloat)
        case below
        case offscreenBelow

        var isInline: Bool {
            switch self {
            case .below, .approaching: true
            case .passed, .offscreenBelow: false
            }
        }
    }

    struct Presentation: Equatable {
        let headerID: String
        let offset: CGFloat

        var opacity: Double {
            // Fade over the gap above the capsule, before its top can be clipped.
            let remaining = min(1, max(0, 1 + offset / TimelineDatePinning.verticalPadding))
            return remaining * remaining * (3 - 2 * remaining)
        }
    }

    static func position(
        minY: CGFloat, height: CGFloat, viewportHeight: CGFloat = .infinity, isFirst: Bool = false
    ) -> Position {
        guard minY.isFinite, height.isFinite, height > 0 else { return .below }
        if minY + verticalPadding >= viewportHeight { return .offscreenBelow }
        if isFirst {
            // The first label has no preceding pill to push away. Hand off only
            // when the label itself, inside the row's vertical padding, leaves view.
            return minY + height - verticalPadding <= 0 ? .passed : .below
        }
        if minY <= 0 { return .passed }
        if minY < height { return .approaching(offset: minY - height) }
        return .below
    }

    /// `topRowHeaderID` is the header of the day the topmost visible row belongs
    /// to. A lazy timeline lays out only the headers near the viewport, so the
    /// rest report no position; the top row still says which day is on screen.
    static func presentation(
        orderedHeaderIDs: [String],
        positions: [String: Position],
        topRowHeaderID: String? = nil,
        dayForHeader: (String) -> Date? = { _ in nil }
    ) -> Presentation? {
        if let first = orderedHeaderIDs.first, positions[first]?.isInline == true { return nil }

        // Protocol order can revisit a calendar day; choose a row, not max(date).
        let passed: Int?
        if let topRowHeaderID, let current = orderedHeaderIDs.firstIndex(of: topRowHeaderID) {
            // That day's own header is above the viewport unless it reports being on screen.
            let isAbove = positions[topRowHeaderID].map { $0 == .passed } ?? true
            passed = isAbove ? current : (current > 0 ? current - 1 : nil)
        } else {
            passed = orderedHeaderIDs.lastIndex(where: { positions[$0] == .passed })
        }
        guard let index = passed else { return nil }
        let candidate = orderedHeaderIDs[index]
        // Visibility callbacks can temporarily name a later row while an earlier
        // heading is still inline. Protocol order can also revisit the same day.
        let candidateDay = dayForHeader(candidate)
        let isInline = positions.contains { id, position in
            guard id == candidate || (candidateDay != nil && dayForHeader(id) == candidateDay) else { return false }
            return position.isInline
        }
        guard !isInline else { return nil }
        let offset = orderedHeaderIDs.dropFirst(index + 1).lazy.compactMap { id -> CGFloat? in
            if case .approaching(let offset) = positions[id] { return offset }
            return nil
        }.first ?? 0
        return Presentation(headerID: orderedHeaderIDs[index], offset: offset)
    }
}

import Foundation

nonisolated enum TimelineDatePinning {
    enum Position: Equatable {
        case passed
        case approaching(offset: CGFloat)
        case below
    }

    struct Presentation: Equatable {
        let headerID: String
        let offset: CGFloat
    }

    static func position(minY: CGFloat, height: CGFloat) -> Position {
        guard minY.isFinite, height.isFinite, height > 0 else { return .below }
        if minY <= 0 { return .passed }
        if minY < height { return .approaching(offset: minY - height) }
        return .below
    }

    static func presentation(
        orderedHeaderIDs: [String],
        positions: [String: Position]
    ) -> Presentation? {
        // Protocol order can revisit a calendar day; choose a row, not max(date).
        guard let index = orderedHeaderIDs.lastIndex(where: { positions[$0] == .passed }) else {
            return nil
        }
        let offset = orderedHeaderIDs.dropFirst(index + 1).compactMap { id -> CGFloat? in
            if case .approaching(let offset) = positions[id] { return offset }
            return nil
        }.first ?? 0
        return Presentation(headerID: orderedHeaderIDs[index], offset: offset)
    }
}

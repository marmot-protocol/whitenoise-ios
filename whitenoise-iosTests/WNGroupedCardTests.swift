import SwiftUI
import Testing
@testable import whitenoise_ios

/// `WNGroupedInput` offers the card position as an opt-in, so the mapping from
/// a row's index to its corners is part of that contract: a wrong first/last
/// hands a section a squared-off end on the iOS 18 floor.
struct WNGroupedCardTests {
    @Test func aLoneRowRoundsBothEnds() {
        let position = WNGroupedCardPosition.at(0, of: 1)

        #expect(position == .only)
        #expect(position.topRadius == WNGroupedCardMetrics.cornerRadius)
        #expect(position.bottomRadius == WNGroupedCardMetrics.cornerRadius)
    }

    @Test func aPairRoundsOnlyTheOutsideCorners() {
        let first = WNGroupedCardPosition.at(0, of: 2)
        let last = WNGroupedCardPosition.at(1, of: 2)

        #expect(first == .first)
        #expect(first.topRadius == WNGroupedCardMetrics.cornerRadius)
        #expect(first.bottomRadius == 0)

        #expect(last == .last)
        #expect(last.topRadius == 0)
        #expect(last.bottomRadius == WNGroupedCardMetrics.cornerRadius)
    }

    @Test func interiorRowsStaySquareSoTheCardStaysContinuous() {
        let positions = (0 ..< 4).map { WNGroupedCardPosition.at($0, of: 4) }

        #expect(positions == [.first, .middle, .middle, .last])
        for position in positions[1 ... 2] {
            #expect(position.topRadius == 0)
            #expect(position.bottomRadius == 0)
        }
    }

    @Test func anEmptyOrSingletonCountNeverSplitsTheCard() {
        // A section that renders one row must not ask for `.first` and leave
        // its bottom corners square with nothing below to close them.
        #expect(WNGroupedCardPosition.at(0, of: 0) == .only)
        #expect(WNGroupedCardPosition.at(0, of: 1) == .only)
    }
}

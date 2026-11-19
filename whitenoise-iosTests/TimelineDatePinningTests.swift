import Foundation
import Testing
@testable import whitenoise_ios

struct TimelineDatePinningTests {
    @Test func anInlineHeaderDoesNotAlsoPin() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first"], positions: ["first": .below]
        ) == nil)
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first"], positions: ["first": .approaching(offset: -10)]
        ) == nil)
    }

    @Test func firstDateHandsOffAtTheBottomEdgeOfItsInlineLabel() {
        let labelHeight: CGFloat = 22
        let padding = TimelineDatePinning.verticalPadding
        let rowHeight = labelHeight + 2 * padding
        func pill(labelBottom: CGFloat) -> String? {
            let position = TimelineDatePinning.position(
                minY: labelBottom - labelHeight - padding, height: rowHeight, isFirst: true
            )
            return TimelineDatePinning.presentation(
                orderedHeaderIDs: ["first"], positions: ["first": position], topRowHeaderID: "first"
            )?.headerID
        }

        #expect(pill(labelBottom: 60) == nil)
        #expect(pill(labelBottom: 1) == nil)
        #expect(pill(labelBottom: 0) == "first")
        #expect(pill(labelBottom: -10) == "first")
    }

    @Test func returningToFirstInlineDateOverridesAStaleTopRowFromAnotherDay() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"],
            positions: ["first": .below], topRowHeaderID: "second"
        ) == nil)
    }

    @Test func theLastPassedHeaderPins() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second", "third"],
            positions: ["first": .passed, "second": .passed, "third": .below]
        ) == .init(headerID: "second", offset: 0))
    }

    @Test func anApproachingHeaderPushesThePinnedHeaderAway() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"],
            positions: ["first": .passed, "second": .approaching(offset: -25)]
        ) == .init(headerID: "first", offset: -25))
    }

    @Test func outgoingPillFadesBeforeTheGlassReachesTheTopEdge() {
        func opacity(afterMovingUp distance: CGFloat) -> Double {
            TimelineDatePinning.Presentation(headerID: "first", offset: -distance).opacity
        }

        let gap = TimelineDatePinning.verticalPadding
        #expect(opacity(afterMovingUp: 0) == 1)
        let early = opacity(afterMovingUp: gap / 3)
        let late = opacity(afterMovingUp: 2 * gap / 3)
        #expect(1 > early && early > late && late > 0)
        #expect(opacity(afterMovingUp: gap) == 0)
        #expect(opacity(afterMovingUp: gap + 10) == 0)
    }

    @Test func crossingTheTopReplacesTheHeaderWithoutKeepingItsOffset() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"],
            positions: ["first": .passed, "second": .passed]
        ) == .init(headerID: "second", offset: 0))
    }

    @Test func scrollingBackRestoresThePreviousHeader() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"],
            positions: ["first": .passed, "second": .below]
        ) == .init(headerID: "first", offset: 0))
    }

    @Test func displayOrderWinsWhenCalendarDaysRepeatOrGoBackwards() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["today-first", "yesterday", "today-second"],
            positions: ["today-first": .passed, "yesterday": .passed, "today-second": .below]
        ) == .init(headerID: "yesterday", offset: 0))
    }

    @Test func prunedOrReplacedHeadersCannotRemainPinned() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["replacement"],
            positions: ["removed": .passed, "replacement": .below]
        ) == nil)
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: [], positions: ["removed": .passed]
        ) == nil)
    }

    /// A lazy timeline lays out only the headers near the viewport.
    @Test func aDayWhoseHeaderIsNotLaidOutStillPins() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second", "third"], positions: [:], topRowHeaderID: "second"
        ) == .init(headerID: "second", offset: 0))
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second", "third"],
            positions: ["third": .approaching(offset: -12)], topRowHeaderID: "second"
        ) == .init(headerID: "second", offset: -12))
    }

    @Test func aTopRowWhoseHeaderIsStillOnScreenLeavesThePreviousDayPinned() {
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"],
            positions: ["second": .approaching(offset: -8)], topRowHeaderID: "second"
        ) == .init(headerID: "first", offset: -8))
        #expect(TimelineDatePinning.presentation(
            orderedHeaderIDs: ["first", "second"], positions: ["first": .below], topRowHeaderID: "first"
        ) == nil)
    }

    @Test func anInlineDateCannotAlsoBePinnedDuringAVisibilityChange() {
        let ids = ["monday", "tuesday"]
        #expect(TimelineDatePinning.presentation(orderedHeaderIDs: ids,
            positions: ["monday": .below, "tuesday": .below], topRowHeaderID: "tuesday") == nil)
    }

    @MainActor @Test func anInlineHeaderRemainsMeasuredWhileSiblingRowsChange() {
        let viewport = TimelineDateViewport()
        viewport.headerID = "today"
        viewport.set(.below, for: "today")
        viewport.set(.below, for: "tomorrow")
        viewport.set(nil, for: "tomorrow")
        #expect(TimelineDatePinning.presentation(orderedHeaderIDs: ["today", "tomorrow"],
            positions: viewport.positions, topRowHeaderID: viewport.headerID) == nil)
        viewport.set(.passed, for: "today")
        #expect(TimelineDatePinning.presentation(orderedHeaderIDs: ["today", "tomorrow"],
            positions: viewport.positions, topRowHeaderID: viewport.headerID)?.headerID == "today")
    }

    @Test func repeatedSectionsDoNotDuplicateTheVisibleCalendarDate() {
        let monday = Date(timeIntervalSince1970: 0)
        let days = ["first": monday, "middle": monday.addingTimeInterval(86400), "again": monday]
        let ids = ["first", "middle", "again"]
        #expect(TimelineDatePinning.presentation(orderedHeaderIDs: ids, positions: ["again": .below],
            topRowHeaderID: "first", dayForHeader: { days[$0] }) == nil)
        #expect(TimelineDatePinning.presentation(orderedHeaderIDs: ids, positions: ["again": .offscreenBelow],
            topRowHeaderID: "first", dayForHeader: { days[$0] })?.headerID == "first")
    }

    @Test func geometryChangesOnlyMatterAtTheHeaderTransition() {
        #expect(TimelineDatePinning.position(minY: 100, height: 50) == .below)
        #expect(TimelineDatePinning.position(minY: 50, height: 50) == .below)
        #expect(TimelineDatePinning.position(minY: 25, height: 50) == .approaching(offset: -25))
        #expect(TimelineDatePinning.position(minY: 0, height: 50) == .passed)
        #expect(TimelineDatePinning.position(minY: -100, height: 50) == .passed)
        #expect(TimelineDatePinning.position(minY: 0, height: 0) == .below)
    }
}

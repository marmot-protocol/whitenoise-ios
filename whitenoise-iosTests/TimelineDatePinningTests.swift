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

    @Test func geometryChangesOnlyMatterAtTheHeaderTransition() {
        #expect(TimelineDatePinning.position(minY: 100, height: 50) == .below)
        #expect(TimelineDatePinning.position(minY: 50, height: 50) == .below)
        #expect(TimelineDatePinning.position(minY: 25, height: 50) == .approaching(offset: -25))
        #expect(TimelineDatePinning.position(minY: 0, height: 50) == .passed)
        #expect(TimelineDatePinning.position(minY: -100, height: 50) == .passed)
        #expect(TimelineDatePinning.position(minY: 0, height: 0) == .below)
    }
}

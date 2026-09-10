import Testing
@testable import whitenoise_ios

struct InteractivePopTransitionStateTests {
    @Test func beginningAPopTakesOverNavigationOnce() {
        var state = InteractivePopTransitionState()
        #expect(!state.isNavigating)

        let epoch = state.begin(isComposerFocused: true)
        #expect(epoch == 1)
        #expect(state.isNavigating)

        // A second begin while the same pop is live must not dismiss again.
        #expect(state.begin(isComposerFocused: true) == nil)
        #expect(state.epoch == 1)
    }

    @Test func aCancelledPopRestoresOnlyPreviouslyFocusedComposers() {
        var focused = InteractivePopTransitionState()
        let focusedEpoch = focused.begin(isComposerFocused: true)
        #expect(focused.finish(epoch: focusedEpoch ?? -1, isCancelled: true)
            == .cancelled(restoresComposerFocus: true))
        #expect(!focused.isNavigating)

        var unfocused = InteractivePopTransitionState()
        let unfocusedEpoch = unfocused.begin(isComposerFocused: false)
        #expect(unfocused.finish(epoch: unfocusedEpoch ?? -1, isCancelled: true)
            == .cancelled(restoresComposerFocus: false))
        #expect(!unfocused.isNavigating)
    }

    @Test func aCompletedPopKeepsNavigationOwnershipForever() {
        var state = InteractivePopTransitionState()
        let epoch = state.begin(isComposerFocused: true)
        #expect(state.finish(epoch: epoch ?? -1, isCancelled: false) == .completed)
        #expect(state.isNavigating)
    }

    @Test func aResolvedPopIgnoresEveryFurtherReport() throws {
        var state = InteractivePopTransitionState()
        let began = state.begin(isComposerFocused: true)
        let epoch = try #require(began)
        #expect(state.finish(epoch: epoch, isCancelled: true)
            == .cancelled(restoresComposerFocus: true))
        #expect(state.finish(epoch: epoch, isCancelled: true) == .ignored)
        #expect(state.finish(epoch: epoch, isCancelled: false) == .ignored)
    }

    @Test func aStaleEpochCannotResolveTheCurrentPop() throws {
        var state = InteractivePopTransitionState()
        let began = state.begin(isComposerFocused: true)
        let first = try #require(began)
        _ = state.finish(epoch: first, isCancelled: true)

        let rebegan = state.begin(isComposerFocused: false)
        let second = try #require(rebegan)
        #expect(second != first)
        #expect(state.finish(epoch: first, isCancelled: true) == .ignored)
        #expect(state.isNavigating)
        #expect(state.finish(epoch: second, isCancelled: false) == .completed)
    }

    @Test func reportsThatArriveBeforeAnyPopAreIgnored() {
        var state = InteractivePopTransitionState()
        #expect(state.finish(epoch: 0, isCancelled: true) == .ignored)
        #expect(state.finish(epoch: 1, isCancelled: false) == .ignored)
        #expect(!state.isNavigating)
    }
}

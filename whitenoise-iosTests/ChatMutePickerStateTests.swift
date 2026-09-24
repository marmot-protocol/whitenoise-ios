import Testing
@testable import whitenoise_ios

struct ChatMutePickerStateTests {
    @Test func layoutCannotReopenADismissingOrDismissedPicker() {
        var state = ChatMutePickerState()
        #expect(state.beginPresentation() == true)
        #expect(state.canUpdateAnchor)
        #expect(state.beginPresentation() == false)
        #expect(state.beginDismissal() == true)
        #expect(!state.canUpdateAnchor)
        #expect(state.beginPresentation() == false)
        #expect(state.finish() == true)
        #expect(state.beginPresentation() == false)
        #expect(!state.canUpdateAnchor)
    }

    @Test func actionAndDelegateCallbacksFinishOnlyOnce() {
        var state = ChatMutePickerState()
        #expect(state.beginPresentation() == true)
        #expect(state.beginDismissal() == true)
        #expect(state.beginDismissal() == false)
        #expect(state.finish() == true)
        #expect(state.finish() == false)
        #expect(state.beginDismissal() == false)
    }

    @Test func cancelledInteractiveDismissalKeepsTheSamePresentation() {
        var state = ChatMutePickerState()
        #expect(state.beginPresentation() == true)
        #expect(state.beginDismissal() == true)
        state.cancelInteractiveDismissal()
        #expect(state.canUpdateAnchor)
        #expect(state.beginPresentation() == false)
        #expect(state.beginDismissal() == true)
        #expect(state.finish() == true)
    }

    @Test func teardownBeforePresentationPreventsLateLayoutFromPresenting() {
        var state = ChatMutePickerState()
        #expect(state.finish() == true)
        #expect(state.beginPresentation() == false)
        #expect(state.beginDismissal() == false)
        #expect(state.finish() == false)
    }

    @Test func lateInteractiveCancellationCannotReviveAFinishedPicker() {
        var state = ChatMutePickerState()
        #expect(state.beginPresentation() == true)
        #expect(state.beginDismissal() == true)
        #expect(state.finish() == true)
        state.cancelInteractiveDismissal()
        #expect(!state.canUpdateAnchor)
        #expect(state.beginPresentation() == false)
    }
}

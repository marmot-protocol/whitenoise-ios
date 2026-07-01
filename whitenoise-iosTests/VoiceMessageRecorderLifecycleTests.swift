import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct VoiceMessageRecorderLifecycleTests {
    @Test func meteringTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak let weakRecorder = recorder

        recorder?.startMeteringForTesting()
        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func pendingHoldTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak let weakRecorder = recorder

        recorder?.beginPress { _ in }
        #expect(recorder?.isActive == true)

        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func cancelIfActiveStopsPendingPressBeforeRecorderStarts() {
        let recorder = VoiceMessageRecorder()

        recorder.beginPress { _ in }
        #expect(recorder.isActive)

        recorder.cancelIfActive()

        #expect(!recorder.isActive)
    }

}

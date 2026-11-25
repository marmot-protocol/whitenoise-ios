import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct VoiceMessageRecorderLifecycleTests {
    @Test func activeRecordingProtectionAllowsWritesWhileLockedUntilCompletion() {
        #expect(VoiceRecordingFileProtection.activeRecording == FileProtectionType.completeUnlessOpen)
        #expect(VoiceRecordingFileProtection.completedRecording == FileProtectionType.complete)
    }

    @Test func persistedWaveformBucketsWholeRecordingInsteadOfTailOnly() {
        var accumulator = VoiceRecordingWaveformAccumulator()
        let earlySamples = Array(repeating: CGFloat(0.95), count: MediaWaveformAnalyzer.sampleCount)
        let tailSamples = Array(repeating: CGFloat(0.10), count: MediaWaveformAnalyzer.sampleCount)
        for sample in earlySamples + tailSamples {
            accumulator.append(sample)
        }

        let persisted = accumulator.persistedSamples()

        #expect(persisted.count == MediaWaveformAnalyzer.sampleCount)
        #expect((persisted.first ?? 0) > 0.9)
        #expect((persisted.last ?? 1) < 0.2)
    }

    @Test func releasingARecordingRecorderStopsTheMicrophone() async throws {
        let session = AudioSessionSpy()
        let microphone = VoiceRecordingMicrophoneDouble()
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder(
            audioSession: session,
            microphone: microphone.microphone
        )
        weak let weakRecorder = recorder

        recorder?.beginPress { error in Issue.record(error, "recording failed to start") }
        try await eventually { recorder?.hasStartedRecording == true }
        // Let the metering loop take a reading, so it is mid-loop when the
        // recorder is released.
        try await eventually { recorder?.waveformSamples.isEmpty == false }

        // The metering loop must not keep the recorder alive, so releasing it
        // stops the microphone and hands the audio session back.
        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
        #expect(microphone.stops == 1)
        #expect(session.activeCalls.last?.active == false)
    }

    @Test func slidingLeftDiscardsTheRecordingSoReleasingSendsNothing() async throws {
        let microphone = VoiceRecordingMicrophoneDouble()
        let recorder = VoiceMessageRecorder(audioSession: AudioSessionSpy(), microphone: microphone.microphone)

        recorder.beginPress { error in Issue.record(error, "recording failed to start") }
        try await eventually { recorder.hasStartedRecording }
        recorder.updateDrag(CGSize(width: HoldGesturePolicy.cancelTranslationX - 1, height: 0))

        #expect(!recorder.isActive)
        #expect(microphone.stops == 1)
        #expect(recorder.endPress() == nil)
    }

    @Test func slidingLeftAfterLockingKeepsRecording() async throws {
        let recorder = VoiceMessageRecorder(audioSession: AudioSessionSpy(), microphone: VoiceRecordingMicrophoneDouble().microphone)

        recorder.beginPress { error in Issue.record(error, "recording failed to start") }
        try await eventually { recorder.hasStartedRecording }
        recorder.updateDrag(CGSize(width: 0, height: HoldGesturePolicy.lockTranslationY - 1))
        recorder.updateDrag(CGSize(width: HoldGesturePolicy.cancelTranslationX - 1, height: 0))

        #expect(recorder.isLocked)
        recorder.cancel()
    }

    @Test func aLockedRecordingFinishesIntoADraftAtTheLimit() async throws {
        let session = AudioSessionSpy()
        let microphone = VoiceRecordingMicrophoneDouble()
        let recorder = VoiceMessageRecorder(audioSession: session, microphone: microphone.microphone)
        var finished: [VoiceRecordingResult] = []

        recorder.beginPress { error in
            Issue.record(error, "recording failed to start")
        } onLimitReached: { finished.append($0) }
        try await eventually { recorder.hasStartedRecording }
        recorder.updateDrag(CGSize(width: 0, height: HoldGesturePolicy.lockTranslationY - 1))
        microphone.elapsedSeconds = VoiceRecordingLimit.maxDurationSeconds + 30

        try await eventually { finished.count == 1 }
        #expect((finished.first?.durationSeconds ?? .infinity) <= VoiceRecordingLimit.maxDurationSeconds)
        #expect(microphone.stops == 1)
        #expect(!recorder.isActive)
        #expect(session.activeCalls.last?.active == false)
        #expect(recorder.stopLockedRecording() == nil)
        #expect(microphone.stops == 1)
    }

    @Test func aHeldRecordingFinishesIntoADraftAtTheLimitAndReleasingSendsNothingMore() async throws {
        let microphone = VoiceRecordingMicrophoneDouble()
        let recorder = VoiceMessageRecorder(audioSession: AudioSessionSpy(), microphone: microphone.microphone)
        var finished: [VoiceRecordingResult] = []

        recorder.beginPress { error in
            Issue.record(error, "recording failed to start")
        } onLimitReached: { finished.append($0) }
        try await eventually { recorder.hasStartedRecording }
        microphone.elapsedSeconds = VoiceRecordingLimit.maxDurationSeconds + 30

        try await eventually { finished.count == 1 }
        #expect((finished.first?.durationSeconds ?? .infinity) <= VoiceRecordingLimit.maxDurationSeconds)
        #expect(recorder.endPress() == nil)
        recorder.cancelIfActive()
        #expect(microphone.stops == 1)
        #expect(finished.count == 1)
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

    @Test func keyboardDismissalWaitsUntilRecordingActuallyStarted() {
        #expect(!VoiceMessageRecorder.RecordingState.idle.hasStartedRecording)
        #expect(!VoiceMessageRecorder.RecordingState.pressing.hasStartedRecording)
        #expect(VoiceMessageRecorder.RecordingState.recording(locked: false).hasStartedRecording)
        #expect(VoiceMessageRecorder.RecordingState.recording(locked: true).hasStartedRecording)
    }

}

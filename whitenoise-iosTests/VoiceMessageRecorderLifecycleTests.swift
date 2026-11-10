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

        // The metering loop runs while recording; it must not keep the
        // recorder alive, so releasing it stops the microphone and hands the
        // audio session back.
        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
        #expect(microphone.stops == 1)
        #expect(session.activeCalls.last?.active == false)
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

import AVFoundation
import Foundation
import Synchronization

/// The microphone behind a voice recording. Production asks iOS for record
/// permission and records AAC with `AVAudioRecorder`.
nonisolated struct VoiceRecordingMicrophone: Sendable {
    var requestPermission: @MainActor () async -> Bool
    /// Starts recording into `url`. Throws when recording can't start.
    var startRecording: @MainActor (_ url: URL) throws -> VoiceRecordingTake

    static let live = VoiceRecordingMicrophone(
        requestPermission: {
            await withCheckedContinuation { continuation in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }
        },
        startRecording: { url in
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: MediaQualityStore.quality().audioBitrateBps,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            let completion = VoiceRecorderCompletion()
            recorder.delegate = completion
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: VoiceRecordingLimit.maxDurationSeconds) else {
                throw VoiceMessageRecorder.Failure.startFailed
            }
            let elapsed = {
                completion.finished ? VoiceRecordingLimit.maxDurationSeconds : recorder.currentTime
            }
            return VoiceRecordingTake(
                meter: {
                    recorder.updateMeters()
                    return (elapsed(), recorder.averagePower(forChannel: 0))
                },
                currentTime: elapsed,
                stop: { recorder.stop() }
            )
        }
    )
}

private nonisolated final class VoiceRecorderCompletion: NSObject, AVAudioRecorderDelegate, Sendable {
    private let didFinish = Mutex(false)

    var finished: Bool { didFinish.withLock { $0 } }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard flag else { return }
        didFinish.withLock { $0 = true }
    }
}

/// A voice recording in progress.
struct VoiceRecordingTake {
    /// Refreshes the meters, then returns the elapsed time and the average
    /// power in dBFS.
    var meter: @MainActor () -> (seconds: TimeInterval, averagePower: Float)
    var currentTime: @MainActor () -> TimeInterval
    var stop: @MainActor () -> Void
}

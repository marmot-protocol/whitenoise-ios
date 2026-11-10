import AVFoundation
import Foundation

/// The microphone behind a voice recording. Production asks iOS for record
/// permission and records AAC with `AVAudioRecorder`.
struct VoiceRecordingMicrophone {
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
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw VoiceMessageRecorder.Failure.startFailed }
            return VoiceRecordingTake(
                meter: {
                    recorder.updateMeters()
                    return (recorder.currentTime, recorder.averagePower(forChannel: 0))
                },
                currentTime: { recorder.currentTime },
                stop: { recorder.stop() }
            )
        }
    )
}

/// A voice recording in progress.
struct VoiceRecordingTake {
    /// Refreshes the meters, then returns the elapsed time and the average
    /// power in dBFS.
    var meter: @MainActor () -> (seconds: TimeInterval, averagePower: Float)
    var currentTime: @MainActor () -> TimeInterval
    var stop: @MainActor () -> Void
}

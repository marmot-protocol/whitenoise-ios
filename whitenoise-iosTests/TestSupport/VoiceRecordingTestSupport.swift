@testable import whitenoise_ios
import AVFoundation
import Foundation

/// Records the audio-session calls made through `VoiceAudioSession`.
final class AudioSessionSpy: VoiceAudioSessionConfiguring {
    private(set) var categoryCalls: [(category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)] = []
    private(set) var activeCalls: [(active: Bool, options: AVAudioSession.SetActiveOptions)] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        categoryCalls.append((category, mode, options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeCalls.append((active, options))
    }
}

/// A microphone that grants permission and "records" silence without touching
/// the device, counting how often a recording is stopped.
@MainActor
final class VoiceRecordingMicrophoneDouble {
    private(set) var stops = 0
    var elapsedSeconds: TimeInterval = 0

    var microphone: VoiceRecordingMicrophone {
        VoiceRecordingMicrophone(
            requestPermission: { true },
            startRecording: { [self] _ in
                VoiceRecordingTake(
                    meter: { (self.elapsedSeconds, -160) },
                    currentTime: { self.elapsedSeconds },
                    stop: { self.stops += 1 }
                )
            }
        )
    }
}

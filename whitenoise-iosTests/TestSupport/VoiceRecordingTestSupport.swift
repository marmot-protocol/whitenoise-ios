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
    var permissionGranted = true
    private(set) var stops = 0

    var microphone: VoiceRecordingMicrophone {
        VoiceRecordingMicrophone(
            requestPermission: { [self] in permissionGranted },
            startRecording: { [self] _ in
                VoiceRecordingTake(
                    meter: { (0, -160) },
                    currentTime: { 0 },
                    stop: { self.stops += 1 }
                )
            }
        )
    }
}

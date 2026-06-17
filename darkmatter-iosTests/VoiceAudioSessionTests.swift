import AVFoundation
import Testing
@testable import darkmatter_ios

struct VoiceAudioSessionTests {
    @Test func playbackSessionUsesPlaybackCategoryAndActivates() throws {
        let session = AudioSessionSpy()

        try VoiceAudioSession.configureForPlayback(session)

        #expect(session.categoryCalls.count == 1)
        #expect(session.categoryCalls.first?.category == .playback)
        #expect(session.categoryCalls.first?.mode == .spokenAudio)
        #expect(session.categoryCalls.first?.options.isEmpty == true)
        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == true)
        #expect(session.activeCalls.first?.options.isEmpty == true)
    }

    @Test func recordingSessionUsesPlayAndRecordCategoryAndActivates() throws {
        let session = AudioSessionSpy()

        try VoiceAudioSession.configureForRecording(session)

        #expect(session.categoryCalls.count == 1)
        #expect(session.categoryCalls.first?.category == .playAndRecord)
        #expect(session.categoryCalls.first?.mode == .spokenAudio)
        #expect(session.categoryCalls.first?.options.contains(.allowBluetoothHFP) == true)
        #expect(session.categoryCalls.first?.options.contains(.defaultToSpeaker) == true)
        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == true)
        #expect(session.activeCalls.first?.options.isEmpty == true)
    }

    @Test func deactivationNotifiesOtherAudioSessions() {
        let session = AudioSessionSpy()

        VoiceAudioSession.deactivate(session)

        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == false)
        #expect(session.activeCalls.first?.options.contains(.notifyOthersOnDeactivation) == true)
    }
}

private final class AudioSessionSpy: VoiceAudioSessionConfiguring {
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

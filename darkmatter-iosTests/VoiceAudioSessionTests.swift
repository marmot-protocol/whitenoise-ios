import AVFoundation
import Testing
@testable import darkmatter_ios

struct VoiceAudioSessionTests {
    @Test func playbackSessionUsesPlaybackCategoryAndActivates() throws {
        let session = AudioSessionSpy()

        let lease = try VoiceAudioSession.configureForPlayback(session)
        defer { VoiceAudioSession.deactivate(lease) }

        #expect(session.categoryCalls.count == 1)
        #expect(session.categoryCalls.first?.category == .playback)
        #expect(session.categoryCalls.first?.mode == .spokenAudio)
        #expect(session.categoryCalls.first?.options.isEmpty == true)
        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == true)
        #expect(session.activeCalls.first?.options.isEmpty == true)
    }

    @Test func videoPlaybackSessionUsesPlaybackCategoryWithMoviePlaybackMode() throws {
        let session = AudioSessionSpy()

        let lease = try VoiceAudioSession.configureForVideoPlayback(session)
        defer { VoiceAudioSession.deactivate(lease) }

        #expect(session.categoryCalls.count == 1)
        #expect(session.categoryCalls.first?.category == .playback)
        #expect(session.categoryCalls.first?.mode == .moviePlayback)
        #expect(session.categoryCalls.first?.options.isEmpty == true)
        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == true)
        #expect(session.activeCalls.first?.options.isEmpty == true)
    }

    @Test func recordingSessionUsesPlayAndRecordCategoryAndActivates() throws {
        let session = AudioSessionSpy()

        let lease = try VoiceAudioSession.configureForRecording(session)
        defer { VoiceAudioSession.deactivate(lease) }

        #expect(session.categoryCalls.count == 1)
        #expect(session.categoryCalls.first?.category == .playAndRecord)
        #expect(session.categoryCalls.first?.mode == .spokenAudio)
        #expect(session.categoryCalls.first?.options.contains(.allowBluetoothHFP) == true)
        #expect(session.categoryCalls.first?.options.contains(.defaultToSpeaker) == true)
        #expect(session.activeCalls.count == 1)
        #expect(session.activeCalls.first?.active == true)
        #expect(session.activeCalls.first?.options.isEmpty == true)
    }

    @Test func deactivationNotifiesOtherAudioSessionsWhenLastLeaseReleases() throws {
        let session = AudioSessionSpy()
        let lease = try VoiceAudioSession.configureForPlayback(session)

        VoiceAudioSession.deactivate(lease)

        #expect(session.activeCalls.count == 2)
        #expect(session.activeCalls.last?.active == false)
        #expect(session.activeCalls.last?.options.contains(.notifyOthersOnDeactivation) == true)
    }

    @Test func deactivationWaitsForLastActiveLease() throws {
        let session = AudioSessionSpy()
        let playbackLease = try VoiceAudioSession.configureForPlayback(session)
        let recordingLease = try VoiceAudioSession.configureForRecording(session)

        VoiceAudioSession.deactivate(playbackLease)
        #expect(session.activeCalls.count == 2)
        #expect(session.categoryCalls.count == 2)

        VoiceAudioSession.deactivate(recordingLease)
        #expect(session.activeCalls.count == 3)
        #expect(session.activeCalls.last?.active == false)
        #expect(session.activeCalls.last?.options.contains(.notifyOthersOnDeactivation) == true)
    }

    @Test func deactivationRestoresPreviousCategoryWhenTopLeaseReleases() throws {
        let session = AudioSessionSpy()
        let playbackLease = try VoiceAudioSession.configureForPlayback(session)
        let recordingLease = try VoiceAudioSession.configureForRecording(session)

        VoiceAudioSession.deactivate(recordingLease)
        #expect(session.activeCalls.count == 2)
        #expect(session.categoryCalls.count == 3)
        #expect(session.categoryCalls.last?.category == .playback)
        #expect(session.categoryCalls.last?.mode == .spokenAudio)
        #expect(session.categoryCalls.last?.options.isEmpty == true)

        VoiceAudioSession.deactivate(playbackLease)
        #expect(session.activeCalls.count == 3)
        #expect(session.activeCalls.last?.active == false)
        #expect(session.activeCalls.last?.options.contains(.notifyOthersOnDeactivation) == true)
    }

    @Test func deactivationWithoutLeaseDoesNothing() {
        let session = AudioSessionSpy()

        VoiceAudioSession.deactivate(nil)

        #expect(session.activeCalls.isEmpty)
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

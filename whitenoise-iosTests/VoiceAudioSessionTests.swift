import AVFoundation
import Testing
@testable import whitenoise_ios

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

struct VideoPlaybackLeaseActionTests {
    @Test func playingWithoutLeaseAcquires() {
        #expect(VideoPlaybackLeaseAction.resolve(status: .playing, hasLease: false) == .acquire)
    }

    @Test func playingWithLeaseDoesNotReacquire() {
        // Repeated `.playing` notifications must not stack redundant leases.
        #expect(VideoPlaybackLeaseAction.resolve(status: .playing, hasLease: true) == .none)
    }

    @Test func pausedWithLeaseReleases() {
        // User pause via the system transport control leaves the player paused;
        // the active `.playback`/`.moviePlayback` lease must be released.
        #expect(VideoPlaybackLeaseAction.resolve(status: .paused, hasLease: true) == .release)
    }

    @Test func endOfItemReleasesHeldLease() {
        // Reaching end-of-item also leaves the player in `.paused`, so the lease
        // must be released rather than left active indefinitely after playback.
        #expect(VideoPlaybackLeaseAction.resolve(status: .paused, hasLease: true) == .release)
    }

    @Test func pausedWithoutLeaseDoesNothing() {
        #expect(VideoPlaybackLeaseAction.resolve(status: .paused, hasLease: false) == .none)
    }

    @Test func bufferingKeepsCurrentLease() {
        // Stalling/buffering while still intending to play must keep the lease.
        #expect(VideoPlaybackLeaseAction.resolve(status: .waitingToPlayAtSpecifiedRate, hasLease: true) == .none)
        #expect(VideoPlaybackLeaseAction.resolve(status: .waitingToPlayAtSpecifiedRate, hasLease: false) == .none)
    }
}

struct AudioPlaybackLoadOutcomeTests {
    @Test func liveLoadProceedsToPlayback() {
        // A load that completes while the view is still on screen (task not
        // cancelled) must start playback as usual.
        #expect(AudioPlaybackLoadOutcome.resolve(isCancelled: false) == .proceed)
    }

    @Test func cancelledLoadAbortsBeforeStartingPlayback() {
        // The view disappeared mid-load and `stopPlayback` cancelled the task.
        // The load must abort rather than start invisible, uncontrollable
        // playback and acquire the `.playback` audio-session lease on a gone view.
        #expect(AudioPlaybackLoadOutcome.resolve(isCancelled: true) == .abort)
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

import AVFoundation
import Testing
@testable import whitenoise_ios

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

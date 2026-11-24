import Foundation
import Testing
@testable import whitenoise_ios

struct MessageAudioPlayerPreparerTests {
    @MainActor
    @Test func preparedPlayerWorkRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let ranOnMainThread = try await MessageAudioPlayerPreparer.detachedPreparedValue(priority: .userInitiated) {
            Thread.isMainThread
        }

        #expect(ranOnMainThread == false)
    }

    @MainActor
    @Test func durationWorkRunsOffMainThreadWhenCalledFromMainActor() async {
        let ranOnMainThread = await MessageAudioPlayerPreparer.detachedValue(priority: .utility) {
            Thread.isMainThread
        }

        #expect(ranOnMainThread == false)
    }
}

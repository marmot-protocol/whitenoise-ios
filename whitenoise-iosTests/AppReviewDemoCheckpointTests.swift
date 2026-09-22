import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct AppReviewDemoCheckpointTests {
    @Test func partialSetupRoundTripsForResume() throws {
        let suiteName = "AppReviewDemoCheckpointTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppReviewDemoCheckpointStore(defaults: defaults)
        let checkpoint = AppReviewDemoCheckpoint(
            originalAccountRef: "original-ref",
            originalAccountIdHex: "original-id",
            initialAccountRefs: ["original-ref"],
            johnnyAccountRef: "johnny-ref",
            johnnyAccountIdHex: "johnny-id",
            johnnyProfilePublished: true,
            groupIdHex: "group-id",
            completed: false
        )

        try store.save(checkpoint)

        #expect(store.load() == checkpoint)
    }

    @Test func clearRemovesOnlyTheResumeCheckpoint() throws {
        let suiteName = "AppReviewDemoCheckpointTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppReviewDemoCheckpointStore(defaults: defaults)
        let checkpoint = AppReviewDemoCheckpoint(
            originalAccountRef: "original-ref",
            originalAccountIdHex: "original-id",
            initialAccountRefs: ["original-ref"]
        )
        defaults.set("preserved", forKey: "unrelated")
        try store.save(checkpoint)

        store.clear()

        #expect(store.load() == nil)
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }

    @Test func malformedCheckpointDoesNotBecomeResumable() throws {
        let suiteName = "AppReviewDemoCheckpointTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppReviewDemoCheckpointStore(defaults: defaults)
        defaults.set(Data("not-json".utf8), forKey: AppReviewDemoCheckpointStore.storageKey)

        #expect(store.load() == nil)
    }
}

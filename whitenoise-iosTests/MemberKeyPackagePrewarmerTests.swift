import Testing
@testable import whitenoise_ios

@MainActor
struct MemberKeyPackagePrewarmerTests {
    @Test func unchangedSelectionDoesNotRestartPendingOrCompletedLookup() async {
        let warmer = MemberKeyPackagePrewarmer()
        defer { warmer.cancel() }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var iterator = stream.makeAsyncIterator()
        let warm: @MainActor ([String]) async -> Void = { _ in continuation.yield(()) }

        #expect(warmer.schedule(memberRefs: ["alice", "bob"], accountRef: "account",
                                runtimeGeneration: 1, debounce: .zero, prewarm: warm))
        #expect(!warmer.schedule(memberRefs: ["bob", "alice"], accountRef: "account",
                                 runtimeGeneration: 1, debounce: .zero, prewarm: warm))
        _ = await iterator.next()
        #expect(!warmer.schedule(memberRefs: ["alice", "bob"], accountRef: "account",
                                 runtimeGeneration: 1, debounce: .zero, prewarm: warm))
    }

    @Test func selectionAccountRuntimeAndDismissalInvalidateDeduplication() {
        let warmer = MemberKeyPackagePrewarmer()
        defer { warmer.cancel() }
        func schedule(_ refs: [String] = ["alice"], account: String = "account", generation: Int = 1) -> Bool {
            warmer.schedule(memberRefs: refs, accountRef: account, runtimeGeneration: generation,
                            debounce: .seconds(60)) { _ in Issue.record("cancelled lookup ran") }
        }
        #expect(schedule())
        #expect(!schedule())
        #expect(schedule(["bob"]))
        #expect(schedule(["bob"], account: "other"))
        #expect(schedule(["bob"], account: "other", generation: 2))
        #expect(!schedule([]))
        #expect(schedule())
        warmer.cancel()
        #expect(schedule())
    }
}

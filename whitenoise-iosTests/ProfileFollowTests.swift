import Foundation
import Testing

@testable import whitenoise_ios

@MainActor
struct ProfileFollowTests {
    private let peer = String(repeating: "dd", count: 32)
    private var context: ProfileFollowContext {
        ProfileFollowContext(accountRef: "owner", peerAccountIdHex: peer, runtimeGeneration: 1)
    }

    @Test func ownIdentitiesAndInvalidKeysCannotBeFollowed() {
        #expect(!ProfileFollowContext.canFollow(peer.uppercased(), localAccountIds: [peer]))
        #expect(!ProfileFollowContext.canFollow("invalid", localAccountIds: []))
        #expect(ProfileFollowContext.canFollow(peer, localAccountIds: [String(repeating: "aa", count: 32)]))
    }

    @Test func loadFailureStaysUnknownAndCanBeRetried() async throws {
        let model = ProfileFollowModel()
        await model.load(context: context) { throw FollowFailure.offline }
        #expect(model.isFollowing == nil)
        #expect(model.loadFailed)
        #expect(!model.isLoading)
        let ignored = try await model.toggle(context: context) { _ in
            Issue.record("Unknown follow status must not publish a replacement")
            return true
        }
        #expect(ignored == nil)

        await model.load(context: context) { true }
        #expect(model.isFollowing == true)
        #expect(!model.loadFailed)
    }

    @Test func toggleUsesThePublishedResultAndPreservesStateOnFailure() async throws {
        let model = ProfileFollowModel()
        await model.load(context: context) { true }
        let unchanged = try await model.toggle(context: context) { desired in
            #expect(!desired)
            return true
        }
        #expect(unchanged == true)
        #expect(model.isFollowing == true)

        do {
            _ = try await model.toggle(context: context) { _ in throw FollowFailure.offline }
            Issue.record("Expected the publish failure")
        } catch FollowFailure.offline {}
        #expect(model.isFollowing == true)
        #expect(!model.isUpdating)

        let updated = try await model.toggle(context: context) { $0 }
        #expect(updated == false)
        #expect(model.isFollowing == false)
    }

    @Test func oldLoadCannotOverwriteANewAccountOrRuntime() async {
        let model = ProfileFollowModel()
        let gate = FollowReadGate()
        let oldLoad = Task { await model.load(context: context) { await gate.read() } }
        await gate.waitUntilReading()

        let replacement = ProfileFollowContext(accountRef: "another", peerAccountIdHex: peer, runtimeGeneration: 2)
        await model.load(context: replacement) { false }
        gate.finish(true)
        await oldLoad.value

        #expect(model.isFollowing == false)
        #expect(!model.isLoading)
    }

    @Test func duplicatePublishesAndOldCompletionAreIgnored() async throws {
        let model = ProfileFollowModel()
        await model.load(context: context) { false }
        let gate = FollowReadGate()
        let oldToggle = Task { try await model.toggle(context: context) { _ in await gate.read() } }
        await gate.waitUntilReading()
        await model.load(context: context) {
            Issue.record("Reappearing must not reload stale state during a publish")
            return false
        }
        #expect(model.isUpdating)
        let duplicate = try await model.toggle(context: context) { _ in
            Issue.record("A second publish must not start")
            return true
        }
        #expect(duplicate == nil)

        await model.load(context: nil) {
            Issue.record("An unavailable runtime must not read follow state")
            return false
        }
        gate.finish(true)
        #expect(try await oldToggle.value == nil)
        #expect(model.isFollowing == nil)
        #expect(!model.isUpdating)
    }

    @Test func differentContextCannotPublishBeforeReload() async throws {
        let model = ProfileFollowModel()
        await model.load(context: context) { false }
        let replacement = ProfileFollowContext(accountRef: "another", peerAccountIdHex: peer, runtimeGeneration: 1)
        let result = try await model.toggle(context: replacement) { _ in
            Issue.record("The displayed relationship belongs to another account")
            return true
        }
        #expect(result == nil)
    }
}

private enum FollowFailure: Error { case offline }

@MainActor
private final class FollowReadGate {
    private var pendingRead: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func read() async -> Bool {
        await withCheckedContinuation { continuation in
            pendingRead = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilReading() async {
        guard pendingRead == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ value: Bool) {
        pendingRead?.resume(returning: value)
        pendingRead = nil
    }
}

import Foundation
import Observation

struct ProfileFollowContext: Hashable {
    let accountRef: String
    let peerAccountIdHex: String
    let runtimeGeneration: Int

    static func canFollow(_ peer: String, localAccountIds: [String]) -> Bool {
        guard Hex.is32Bytes(peer) else { return false }
        return !localAccountIds.contains { $0.caseInsensitiveCompare(peer) == .orderedSame }
    }
}

@MainActor
@Observable
final class ProfileFollowModel {
    private(set) var isFollowing: Bool?
    private(set) var isLoading = false
    private(set) var isUpdating = false
    private(set) var loadFailed = false
    private var context: ProfileFollowContext?
    private var generation = 0

    func load(
        context: ProfileFollowContext?,
        read: () async throws -> Bool
    ) async {
        // Reappearing during a publish must not read the old value or unlock a second publish.
        if self.context == context, isUpdating { return }
        generation += 1
        let request = generation
        self.context = context
        isFollowing = nil
        isUpdating = false
        loadFailed = false
        isLoading = context != nil
        guard context != nil else { return }
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await read()
            guard generation == request, !Task.isCancelled else { return }
            isFollowing = value
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    func toggle(
        context: ProfileFollowContext,
        publish: (Bool) async throws -> Bool
    ) async throws -> Bool? {
        guard self.context == context, let isFollowing, !isLoading, !isUpdating else { return nil }
        let request = generation
        isUpdating = true
        defer { if generation == request { isUpdating = false } }
        do {
            let updated = try await publish(!isFollowing)
            guard generation == request, !Task.isCancelled else { return nil }
            self.isFollowing = updated
            return updated
        } catch {
            guard generation == request, !Task.isCancelled else { return nil }
            throw error
        }
    }
}

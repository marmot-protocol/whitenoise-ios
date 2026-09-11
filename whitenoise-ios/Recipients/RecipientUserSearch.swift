import Foundation
import MarmotKit

struct RecipientUserSearchOperations {
    let searchUsers: @MainActor () async throws -> any UserSearchSubscriptionProtocol
    let accountFollows: @MainActor () async throws -> Set<String>
}

private enum RecipientUserSearchError: Error {
    case appStateUnavailable
}

/// Screen-lifetime live search over the active account's Marmot web of trust.
///
/// Results and their profiles deliberately remain ephemeral. MDK does not
/// promote discovered strangers into the local directory, and the UI mirrors
/// that boundary until the user explicitly starts a conversation or invite.
@MainActor
@Observable
final class RecipientUserSearch {
    private(set) var results: [UserDirectorySearchResultFfi] = []
    private(set) var followedAccountIds: Set<String> = []
    private(set) var isSearching = false
    private(set) var isIncomplete = false
    private(set) var didFail = false

    private var task: Task<Void, Never>?
    private var followsTask: Task<Void, Never>?
    private var requestID: UUID?
    private var activeQuery = ""
    private var followStatusOverrides: [String: Bool] = [:]

    private static let radiusStart: UInt8 = 1
    private static let radiusEnd: UInt8 = 2

    var candidates: [RecipientCandidate] {
        results.map {
            RecipientCandidate(
                accountIdHex: $0.accountIdHex.lowercased(),
                npub: $0.npub,
                lastActivityAt: 0,
                directChatGroupIdHex: nil,
                sharedChatCount: 0,
                searchProfile: $0.profile,
                searchRadius: $0.radius,
                isFollowedBySearcher: followedAccountIds.contains($0.accountIdHex.lowercased())
            )
        }
    }

    func update(
        query rawQuery: String,
        isIdentifierQuery: Bool,
        using appState: AppState
    ) {
        let query = Self.normalizedQuery(rawQuery)
        resetForUpdate(query: query)

        guard Self.shouldSearch(query: query, isIdentifierQuery: isIdentifierQuery),
              let accountIdHex = appState.activeAccount?.accountIdHex,
              let accountRef = appState.activeAccountRef
        else { return }

        startRequest(query: query, debounce: .milliseconds(300)) { [weak appState] in
            guard let appState else { throw RecipientUserSearchError.appStateUnavailable }
            let client = try appState.currentMarmotClient()
            return RecipientUserSearchOperations(
                searchUsers: {
                    try await client.marmot.searchUsers(
                        accountIdHex: accountIdHex,
                        query: query,
                        radiusStart: Self.radiusStart,
                        radiusEnd: Self.radiusEnd
                    )
                },
                accountFollows: {
                    try await client.accountFollows(accountRef: accountRef)
                }
            )
        }
    }

    func updateForTesting(
        query rawQuery: String,
        debounce: Duration = .zero,
        makeOperations: @escaping @MainActor () throws -> RecipientUserSearchOperations
    ) {
        let query = Self.normalizedQuery(rawQuery)
        resetForUpdate(query: query)
        guard Self.shouldSearch(query: query, isIdentifierQuery: false) else { return }
        startRequest(query: query, debounce: debounce, makeOperations: makeOperations)
    }

    private func startRequest(
        query: String,
        debounce: Duration,
        makeOperations: @escaping @MainActor () throws -> RecipientUserSearchOperations
    ) {
        let id = UUID()
        requestID = id
        isSearching = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                guard let self else { return }
                let operations = try makeOperations()
                // Follow metadata only reorders rows; it must never gate streamed matches.
                let followsTask = Task { [weak self] in
                    let followedAccountIds = (try? await operations.accountFollows()) ?? []
                    guard let self,
                          self.requestIsCurrent(id: id, query: query),
                          !Task.isCancelled
                    else { return }
                    self.followedAccountIds = self.applyingFollowStatusOverrides(
                        to: followedAccountIds
                    )
                    self.results = Self.sortedUniqueResults(
                        self.results,
                        followedAccountIds: self.followedAccountIds
                    )
                    self.finishFollowsRequest(id: id, query: query)
                }
                self.followsTask = followsTask
                let subscription = try await operations.searchUsers()
                guard self.requestIsCurrent(id: id, query: query), !Task.isCancelled else {
                    return
                }
                await self.consume(
                    subscription,
                    requestID: id,
                    query: query
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.finishFailedRequest(id: id, query: query)
            }
        }
    }

    private func resetForUpdate(query: String) {
        task?.cancel()
        followsTask?.cancel()
        task = nil
        followsTask = nil
        requestID = nil
        activeQuery = query
        followStatusOverrides = [:]
        results = []
        followedAccountIds = []
        isSearching = false
        isIncomplete = false
        didFail = false
    }

    func retry(using appState: AppState) {
        update(query: activeQuery, isIdentifierQuery: false, using: appState)
    }

    func cancel() {
        task?.cancel()
        followsTask?.cancel()
        task = nil
        followsTask = nil
        requestID = nil
        followStatusOverrides = [:]
        results = []
        followedAccountIds = []
        isSearching = false
        isIncomplete = false
        didFail = false
    }

    private func consume(
        _ subscription: any UserSearchSubscriptionProtocol,
        requestID id: UUID,
        query: String
    ) async {
        var aggregate: [UserDirectorySearchResultFfi] = []
        while !Task.isCancelled, let update = await subscription.nextUpdate() {
            guard requestIsCurrent(id: id, query: query), !Task.isCancelled else { return }
            aggregate.append(contentsOf: update.newResults)
            aggregate = Self.applyingReplacements(update.updatedResults, to: aggregate)
            results = Self.sortedUniqueResults(
                aggregate,
                followedAccountIds: followedAccountIds
            )

            switch update.trigger {
            case .radiusTimeout, .radiusTruncated:
                isIncomplete = true
            case .error:
                didFail = true
            case .searchCompleted:
                finishRequest(id: id, query: query)
                return
            case .radiusStarted, .resultsFound, .discoveryResultsFound, .cachedResultsFound, .radiusCompleted:
                break
            }
        }
        finishRequest(id: id, query: query)
    }

    private func finishFailedRequest(id: UUID, query: String) {
        guard requestIsCurrent(id: id, query: query) else { return }
        followsTask?.cancel()
        followsTask = nil
        didFail = true
        finishRequest(id: id, query: query)
    }

    private func finishRequest(id: UUID, query: String) {
        guard requestIsCurrent(id: id, query: query) else { return }
        isSearching = false
        task = nil
        if followsTask == nil {
            requestID = nil
        }
    }

    private func finishFollowsRequest(id: UUID, query: String) {
        guard requestIsCurrent(id: id, query: query) else { return }
        followsTask = nil
        if task == nil {
            requestID = nil
        }
    }

    private func requestIsCurrent(id: UUID, query: String) -> Bool {
        requestID == id && activeQuery == query
    }

    func setFollowStatus(accountIdHex: String, isFollowing: Bool) {
        let accountIdHex = accountIdHex.lowercased()
        followStatusOverrides[accountIdHex] = isFollowing
        if isFollowing {
            followedAccountIds.insert(accountIdHex)
        } else {
            followedAccountIds.remove(accountIdHex)
        }
        results = Self.sortedUniqueResults(
            results,
            followedAccountIds: followedAccountIds
        )
    }

    private func applyingFollowStatusOverrides(to followedAccountIds: Set<String>) -> Set<String> {
        var followedAccountIds = followedAccountIds
        for (accountIdHex, isFollowing) in followStatusOverrides {
            if isFollowing {
                followedAccountIds.insert(accountIdHex)
            } else {
                followedAccountIds.remove(accountIdHex)
            }
        }
        return followedAccountIds
    }

    nonisolated static func shouldSearch(query: String, isIdentifierQuery: Bool) -> Bool {
        !isIdentifierQuery && !normalizedQuery(query).isEmpty
    }

    nonisolated static func applyingReplacements(
        _ replacements: [UserDirectorySearchResultFfi],
        to aggregate: [UserDirectorySearchResultFfi]
    ) -> [UserDirectorySearchResultFfi] {
        guard !replacements.isEmpty else { return aggregate }
        var byAccountId: [String: UserDirectorySearchResultFfi] = [:]
        for replacement in replacements {
            byAccountId[replacement.accountIdHex.lowercased()] = replacement
        }
        var merged = aggregate.map { byAccountId[$0.accountIdHex.lowercased()] ?? $0 }
        let known = Set(aggregate.map { $0.accountIdHex.lowercased() })
        merged.append(contentsOf: replacements.filter { !known.contains($0.accountIdHex.lowercased()) })
        return merged
    }

    nonisolated static func sortedUniqueResults(
        _ results: [UserDirectorySearchResultFfi],
        followedAccountIds: Set<String> = []
    ) -> [UserDirectorySearchResultFfi] {
        let sorted = results.sorted {
            let lhsFollowed = followedAccountIds.contains($0.accountIdHex.lowercased())
            let rhsFollowed = followedAccountIds.contains($1.accountIdHex.lowercased())
            if lhsFollowed != rhsFollowed {
                return lhsFollowed
            }
            if $0.radius != $1.radius {
                return $0.radius < $1.radius
            }
            let lhsProviderRank = $0.providerRank ?? -.infinity
            let rhsProviderRank = $1.providerRank ?? -.infinity
            if lhsProviderRank != rhsProviderRank {
                return lhsProviderRank > rhsProviderRank
            }
            let lhsQuality = matchQualityRank($0.matchQuality)
            let rhsQuality = matchQualityRank($1.matchQuality)
            if lhsQuality != rhsQuality {
                return lhsQuality < rhsQuality
            }
            let lhsField = matchedFieldRank($0.matchedField)
            let rhsField = matchedFieldRank($1.matchedField)
            if lhsField != rhsField {
                return lhsField < rhsField
            }
            return $0.accountIdHex < $1.accountIdHex
        }
        var seen: Set<String> = []
        return sorted.filter {
            seen.insert($0.accountIdHex.lowercased()).inserted
        }
    }

    private nonisolated static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func matchQualityRank(_ quality: MatchQualityFfi) -> Int {
        switch quality {
        case .exact: 0
        case .prefix: 1
        case .contains: 2
        }
    }

    private nonisolated static func matchedFieldRank(_ field: MatchedFieldFfi) -> Int {
        switch field {
        case .name: 0
        case .nip05: 1
        case .displayName: 2
        case .about: 3
        case .npub: 4
        case .pubkey: 5
        }
    }
}

import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct RecipientSearchTests {
    private let alice = String(repeating: "aa", count: 32)
    private let bob = String(repeating: "bb", count: 32)
    private let carol = String(repeating: "cc", count: 32)

    @Test func membershipPagesAreUniqueBoundedAndStable() {
        let ids = (0..<205).map { "group-\($0)" } + ["group-4", "group-204"]

        let pages = GroupMembershipPageLoader.pages(for: ids)

        #expect(pages.map(\.count) == [100, 100, 5])
        #expect(pages.flatMap { $0 } == (0..<205).map { "group-\($0)" })
    }

    @Test func membershipLoaderUsesTenCommandsForOneThousandGroups() async throws {
        let ids = (0..<1_000).map { "group-\($0)" }
        var requestedPages: [[String]] = []

        let result = try await GroupMembershipPageLoader.load(
            groupIdsHex: ids,
            pageRead: { page in
                requestedPages.append(page)
                return page.map {
                    AppGroupMemberIdsFfi(
                        groupIdHex: $0,
                        memberIdsHex: ["member-\($0)"],
                        adminIdsHex: ["admin-\($0)"]
                    )
                }
            },
            fallbackRead: { _ in
                Issue.record("a successful page must not fall back")
                return []
            }
        )

        #expect(requestedPages.count == 10)
        #expect(requestedPages.allSatisfy { $0.count == 100 })
        #expect(result.pageReadCount == 10)
        #expect(result.fallbackReadCount == 0)
        #expect(result.memberIdsByGroupId.count == 1_000)
        #expect(result.adminIdsByGroupId.count == 1_000)
        #expect(result.adminIdsByGroupId["group-42"] == ["admin-group-42"])
        #expect(result.firstUnresolvedError == nil)
    }

    @Test func failedMembershipPageFallsBackPerGroupAndKeepsPartialSuccess() async throws {
        let ids = ["good-a", "bad", "good-b"]

        let result = try await GroupMembershipPageLoader.load(
            groupIdsHex: ids,
            pageRead: { _ in throw MembershipReadFailure.page },
            fallbackRead: { groupIdHex in
                if groupIdHex == "bad" { throw MembershipReadFailure.group }
                return ["member-\(groupIdHex)"]
            }
        )

        #expect(result.memberIdsByGroupId["good-a"] == ["member-good-a"])
        #expect(result.memberIdsByGroupId["good-b"] == ["member-good-b"])
        #expect(result.memberIdsByGroupId["bad"] == nil)
        #expect(result.pageReadCount == 1)
        #expect(result.fallbackReadCount == 3)
        #expect(result.firstUnresolvedError != nil)
    }

    @Test func malformedMembershipPageResponseUsesTheSameSafeFallback() async throws {
        let ids = ["first", "second"]

        let result = try await GroupMembershipPageLoader.load(
            groupIdsHex: ids,
            pageRead: { _ in
                [AppGroupMemberIdsFfi(
                    groupIdHex: "wrong",
                    memberIdsHex: [],
                    adminIdsHex: []
                )]
            },
            fallbackRead: { ["fallback-\($0)"] }
        )

        #expect(result.memberIdsByGroupId["first"] == ["fallback-first"])
        #expect(result.memberIdsByGroupId["second"] == ["fallback-second"])
        #expect(result.firstUnresolvedError == nil)
    }

    @Test func completingOlderDirectoryLoadCannotClearNewerTaskSlot() {
        let older = UUID()
        let newer = UUID()

        #expect(!RecipientDirectory.shouldClearLoadTask(
            currentTaskID: newer,
            completingTaskID: older
        ))
        #expect(RecipientDirectory.shouldClearLoadTask(
            currentTaskID: newer,
            completingTaskID: newer
        ))
    }

    @Test func directoryResetsAndRejectsCommitsAcrossAccountSwitches() {
        let task = UUID()

        #expect(RecipientDirectory.shouldResetForAccountChange(
            loadedAccountRef: "account-a",
            loadingAccountRef: nil,
            requestedAccountRef: "account-b"
        ))
        #expect(!RecipientDirectory.shouldResetForAccountChange(
            loadedAccountRef: "account-a",
            loadingAccountRef: "account-a",
            requestedAccountRef: "account-a"
        ))
        #expect(!RecipientDirectory.loadRequestIsCurrent(
            currentTaskID: task,
            currentAccountRef: "account-a",
            activeAccountRef: "account-b",
            completingTaskID: task,
            completingAccountRef: "account-a"
        ))
        #expect(RecipientDirectory.loadRequestIsCurrent(
            currentTaskID: task,
            currentAccountRef: "account-b",
            activeAccountRef: "account-b",
            completingTaskID: task,
            completingAccountRef: "account-b"
        ))
    }

    @Test func blankQueryReturnsAllCandidatesInInputOrder() {
        let candidates = [candidate(alice), candidate(bob)]

        let result = RecipientSearch.browse(candidates, query: "   ") { _ in .init() }

        #expect(result.map(\.accountIdHex) == [alice, bob])
    }

    @Test func matchesNamesCaseAndDiacriticInsensitively() {
        let candidates = [candidate(alice), candidate(bob)]

        let result = RecipientSearch.browse(candidates, query: "  JOSÉ ") { candidate in
            candidate.accountIdHex == self.alice ? .init(displayName: "jose garcía") : .init()
        }
        // The stored field's diacritics must fold too, not just the query's.
        let foldedField = RecipientSearch.browse(candidates, query: "garcia") { candidate in
            candidate.accountIdHex == self.alice ? .init(displayName: "José García") : .init()
        }

        #expect(result.map(\.accountIdHex) == [alice])
        #expect(foldedField.map(\.accountIdHex) == [alice])
    }

    @Test func ranksNamePrefixMatchesBeforeContainedMatches() {
        let candidates = [candidate(alice), candidate(bob), candidate(carol)]

        let result = RecipientSearch.browse(candidates, query: "an") { candidate in
            switch candidate.accountIdHex {
            case self.alice: .init(displayName: "Joanne")
            case self.bob: .init(displayName: "Anders")
            default: .init(displayName: "Zoe")
            }
        }

        #expect(result.map(\.accountIdHex) == [bob, alice])
    }

    @Test func matchesPrivateNicknameAndNip05() {
        let candidates = [candidate(alice), candidate(bob)]

        let byNickname = RecipientSearch.browse(candidates, query: "boss") { candidate in
            candidate.accountIdHex == self.alice ? .init(nickname: "The Boss") : .init()
        }
        let byAddress = RecipientSearch.browse(candidates, query: "example.com") { candidate in
            candidate.accountIdHex == self.bob ? .init(nip05: "bob@example.com") : .init()
        }

        #expect(byNickname.map(\.accountIdHex) == [alice])
        #expect(byAddress.map(\.accountIdHex) == [bob])
    }

    @Test func matchesNpubAndHexPrefixesButNotShortFragments() {
        let candidates = [candidate(alice)]
        let npubPrefix = String(candidates[0].npub.prefix(8))

        let byNpub = RecipientSearch.browse(candidates, query: npubPrefix) { _ in .init() }
        let byHex = RecipientSearch.browse(candidates, query: String(alice.prefix(6))) { _ in .init() }
        let tooShort = RecipientSearch.browse(candidates, query: "aa") { _ in .init() }

        #expect(byNpub.map(\.accountIdHex) == [alice])
        #expect(byHex.map(\.accountIdHex) == [alice])
        #expect(tooShort.isEmpty)
    }

    @Test func excludesListedAccountsAndDeduplicatesKeepingFirst() {
        let duplicate = candidate(alice.uppercased())
        let candidates = [candidate(alice), duplicate, candidate(bob)]

        let result = RecipientSearch.browse(
            candidates,
            query: "",
            excludedAccountIds: [bob.uppercased()]
        ) { _ in .init() }

        #expect(result.count == 1)
        #expect(result.first?.accountIdHex == alice)
    }

    @Test func liveSearchRunsForAnyNonemptyFreeTextAndLeavesIdentifiersToResolver() {
        #expect(!RecipientUserSearch.shouldSearch(query: " ", isIdentifierQuery: false))
        #expect(RecipientUserSearch.shouldSearch(query: "a", isIdentifierQuery: false))
        #expect(RecipientUserSearch.shouldSearch(query: "  al  ", isIdentifierQuery: false))
        #expect(!RecipientUserSearch.shouldSearch(query: "alice", isIdentifierQuery: true))
    }

    @Test func streamedResultsRerankAcrossBatchesAndDeduplicateBestMatch() {
        let results = RecipientUserSearch.sortedUniqueResults([
            searchResult(bob, radius: 2, field: .displayName, quality: .prefix),
            searchResult(alice, radius: 1, field: .about, quality: .contains),
            searchResult(carol, radius: 1, field: .name, quality: .exact),
            searchResult(bob, radius: 1, field: .displayName, quality: .prefix),
        ], followedAccountIds: [bob])

        #expect(results.map(\.accountIdHex) == [bob, carol, alice])
        #expect(results.first?.radius == 1)
    }

    @Test func discoveryResultsUseProviderRankBeforeLocalMatchStrength() {
        let results = RecipientUserSearch.sortedUniqueResults([
            searchResult(
                alice,
                radius: .max,
                field: .name,
                quality: .exact,
                providerRank: 0.2
            ),
            searchResult(
                bob,
                radius: .max,
                field: .about,
                quality: .contains,
                providerRank: 0.9
            ),
        ])

        #expect(results.map(\.accountIdHex) == [bob, alice])
    }

    @MainActor
    @Test func streamedResultsDoNotWaitForFollowEnrichment() async {
        let model = RecipientUserSearch()
        let follows = RecipientSearchFollowsGate()
        let result = searchResult(alice, radius: 1, field: .name, quality: .exact)
        let subscription = RecipientSearchSubscriptionStub(updates: [
            UserSearchUpdateFfi(
                trigger: .resultsFound(radius: 1),
                newResults: [result],
                updatedResults: [],
                totalResultCount: 1
            ),
            UserSearchUpdateFfi(
                trigger: .searchCompleted,
                newResults: [],
                updatedResults: [],
                totalResultCount: 1
            ),
        ])

        model.updateForTesting(query: "alice") {
            RecipientUserSearchOperations(
                searchUsers: { subscription },
                accountFollows: {
                    await follows.suspendUntilReleased()
                    return [self.alice]
                }
            )
        }

        await follows.waitUntilStarted()
        await waitForRecipientSearch {
            model.results == [result] && !model.isSearching
        }

        #expect(model.results == [result])
        #expect(!model.isSearching)

        await follows.release()
        await waitForRecipientSearch {
            model.followedAccountIds == [self.alice]
                && model.candidates.first?.isFollowedBySearcher == true
        }
        #expect(model.followedAccountIds == [alice])
        #expect(model.candidates.first?.isFollowedBySearcher == true)
        model.cancel()
    }

    @Test func followedRecipientsSortFirstAndKnownChatContextSurvivesMerge() {
        let knownAlice = candidate(alice)
        let discoveredAlice = RecipientCandidate(
            accountIdHex: alice,
            npub: knownAlice.npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 1,
            isFollowedBySearcher: true
        )
        let discoveredBob = RecipientCandidate(
            accountIdHex: bob,
            npub: candidate(bob).npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 2
        )

        let merged = RecipientSearch.merge(
            known: [knownAlice],
            discovered: [discoveredAlice, discoveredBob],
            excludedAccountIds: []
        )

        #expect(merged.map(\.accountIdHex) == [alice, bob])
        #expect(merged.first?.isFollowedBySearcher == true)
        #expect(merged.first?.sharedChatCount == knownAlice.sharedChatCount)
        #expect(merged.first?.searchRadius == 1)
    }

    @Test func remoteFollowSortsAheadOfKnownNonFollow() {
        let followedBob = RecipientCandidate(
            accountIdHex: bob,
            npub: candidate(bob).npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 1,
            isFollowedBySearcher: true
        )

        let merged = RecipientSearch.merge(
            known: [candidate(alice)],
            discovered: [followedBob]
        )

        #expect(merged.map(\.accountIdHex) == [bob, alice])
        #expect(RecipientSearch.resultContext(for: merged[0], query: "bo") == .youFollow)
        #expect(RecipientSearch.resultContext(for: merged[1], query: "bo") == .searchResult)
        #expect(RecipientSearch.resultContext(for: merged[0], query: "  ") == nil)
    }

    private func candidate(_ hex: String) -> RecipientCandidate {
        RecipientCandidate(
            accountIdHex: hex,
            npub: NostrProfileReference.npub(fromAccountIdHex: hex.lowercased()) ?? hex,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 1
        )
    }

    @Test func updatedResultsReplaceMatchingRowsAndKeepUnknownOnes() {
        let alice = String(repeating: "a", count: 64)
        let bob = String(repeating: "b", count: 64)
        let carol = String(repeating: "c", count: 64)
        let aggregate = [
            searchResult(alice, radius: 2, field: .npub, quality: .prefix),
            searchResult(bob, radius: 2, field: .npub, quality: .prefix),
        ]
        let enrichedAlice = searchResult(
            alice,
            radius: 1,
            field: .name,
            quality: .exact,
            isFollowedBySearcher: true
        )
        let lateCarol = searchResult(carol, radius: 2, field: .name, quality: .exact)

        let merged = RecipientUserSearch.applyingReplacements(
            [enrichedAlice, lateCarol],
            to: aggregate
        )

        #expect(merged.map(\.accountIdHex) == [alice, bob, carol])
        #expect(merged[0] == enrichedAlice)
        #expect(merged[1] == aggregate[1])
    }

    @Test func emptyReplacementsLeaveTheAggregateUntouched() {
        let aggregate = [
            searchResult(String(repeating: "a", count: 64), radius: 1, field: .name, quality: .exact)
        ]
        #expect(RecipientUserSearch.applyingReplacements([], to: aggregate) == aggregate)
    }

    private func searchResult(
        _ hex: String,
        radius: UInt8,
        field: MatchedFieldFfi,
        quality: MatchQualityFfi,
        providerRank: Double? = nil,
        isFollowedBySearcher: Bool = false,
        profile: UserProfileMetadataFfi? = nil
    ) -> UserDirectorySearchResultFfi {
        UserDirectorySearchResultFfi(
            accountIdHex: hex,
            npub: candidate(hex).npub,
            radius: radius,
            isFollowedBySearcher: isFollowedBySearcher,
            matchedField: field,
            matchQuality: quality,
            providerRank: providerRank,
            profile: profile
        )
    }
}

private actor RecipientSearchSubscriptionStub: UserSearchSubscriptionProtocol {
    private var updates: [UserSearchUpdateFfi]

    init(updates: [UserSearchUpdateFfi]) {
        self.updates = updates
    }

    func nextUpdate() async -> UserSearchUpdateFfi? {
        guard !updates.isEmpty else { return nil }
        return updates.removeFirst()
    }
}

private actor RecipientSearchFollowsGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        started = true
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private func waitForRecipientSearch(
    timeout: Duration = .milliseconds(250),
    condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private enum MembershipReadFailure: Error {
    case page
    case group
}

@MainActor
struct ProfileFollowTests {
    private let peer = String(repeating: "dd", count: 32)

    @Test func profileLoadsFollowStatusFromTheBindingAdapter() async {
        let model = ProfileViewModel()
        model.applyResolvedAccount(peer)

        await model.prepareFollowStatus(initialValue: false) {
            true
        }

        #expect(model.isFollowing == true)
        #expect(!model.isLoadingFollow)
    }

    @Test func profileTogglePublishesTheOppositeStateAndUsesReturnedResult() async throws {
        let model = ProfileViewModel()
        let appState = AppState(client: try MarmotClient.testClient())
        model.applyResolvedAccount(peer)
        await model.prepareFollowStatus(initialValue: true, load: nil)
        var requestedState: Bool?

        await model.toggleFollow(using: appState) { desired in
            requestedState = desired
            return desired
        }

        #expect(requestedState == false)
        #expect(model.isFollowing == false)
        #expect(!model.isUpdatingFollow)
    }
}

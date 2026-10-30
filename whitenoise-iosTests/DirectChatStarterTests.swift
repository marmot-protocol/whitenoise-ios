import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct DirectChatStarterTests {
    private let alice = String(repeating: "bb", count: 32)

    @Test func reopensAnExistingDirectChatWithoutCreating() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let starter = directChatStarter { _, _ in
            Issue.record("must not create when an open direct chat exists")
            throw TestError.unexpectedCreate
        }

        let outcome = await starter.start(
            accountIdHex: alice,
            memberRef: alice,
            existingGroupIdHex: "dm-1",
            using: appState
        )

        #expect(outcome == .opened(groupIdHex: "dm-1"))
        #expect(appState.directChatPeerAccountId(accountRef: "account", groupIdHex: "dm-1") == alice)
        #expect(!starter.isCreating)
    }

    @Test func createsWhenNoDirectChatExistsAndClearsRowScopedProgress() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        var observedRefs: [String] = []
        let starter = directChatStarter { accountRef, memberRef in
            observedRefs = [accountRef, memberRef]
            return "new-group"
        }

        let outcome = await starter.start(
            accountIdHex: alice,
            memberRef: alice,
            existingGroupIdHex: nil,
            using: appState
        )

        #expect(outcome == .created(groupIdHex: "new-group"))
        #expect(observedRefs == ["account", alice])
        #expect(appState.directChatPeerAccountId(accountRef: "account", groupIdHex: "new-group") == alice)
        #expect(appState.createdChatListRow(accountRef: "account", groupIdHex: "new-group")?.groupIdHex == "new-group")
        #expect(starter.creatingAccountIdHex == nil)
    }

    @Test func recentDirectPeerHandoffIsAccountScopedAndBounded() throws {
        var store = RecentDirectChatPeerStore(maxAccounts: 1, maxGroupsPerAccount: 1)
        store.record(accountRef: "first", groupIdHex: "old", peerAccountIdHex: alice)
        store.record(accountRef: "first", groupIdHex: "new", peerAccountIdHex: "bob")

        #expect(store.peerAccountId(accountRef: "first", groupIdHex: "old") == nil)
        #expect(store.peerAccountId(accountRef: "first", groupIdHex: "new") == "bob")

        store.record(accountRef: "second", groupIdHex: "other", peerAccountIdHex: "carol")
        #expect(store.peerAccountId(accountRef: "first", groupIdHex: "new") == nil)
        #expect(store.peerAccountId(accountRef: "second", groupIdHex: "other") == "carol")
    }

    @Test func createdChatRowHandoffIsAccountScopedAndBounded() {
        var store = RecentCreatedChatRowStore(maximumRows: 1)
        store.record(accountRef: "first", row: chatListRow(groupIdHex: "old", title: "old"))
        store.record(accountRef: "first", row: chatListRow(groupIdHex: "new", title: "new"))

        #expect(store.row(accountRef: "first", groupIdHex: "old") == nil)
        #expect(store.row(accountRef: "first", groupIdHex: "new")?.title == "new")
        #expect(store.row(accountRef: "second", groupIdHex: "new") == nil)

        store.record(accountRef: "second", row: chatListRow(groupIdHex: "other", title: "other"))
        #expect(store.row(accountRef: "first", groupIdHex: "new") == nil)
        #expect(store.row(accountRef: "second", groupIdHex: "other")?.title == "other")
    }

    @Test func secondTapIsIgnoredWhileTheFirstCreateIsInFlight() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let gate = (entered: TestLatch(), released: TestLatch())
        let starter = directChatStarter { _, _ in
            gate.entered.signal()
            await gate.released.hold()
            return "new-group"
        }

        let first = Task {
            await starter.start(
                accountIdHex: alice,
                memberRef: alice,
                existingGroupIdHex: nil,
                using: appState
            )
        }
        try await gate.entered.wait()
        #expect(starter.creatingAccountIdHex == alice)

        let second = await starter.start(
            accountIdHex: alice,
            memberRef: alice,
            existingGroupIdHex: nil,
            using: appState
        )
        gate.released.signal()

        #expect(second == .ignored)
        #expect(await first.value == .created(groupIdHex: "new-group"))
        #expect(starter.creatingAccountIdHex == nil)
    }

    @Test func failsWithoutAnActiveAccount() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = nil
        let starter = directChatStarter { _, _ in
            Issue.record("no conversation may be created without an active account")
            return "unexpected"
        }

        let outcome = await starter.start(
            accountIdHex: alice,
            memberRef: alice,
            existingGroupIdHex: nil,
            using: appState
        )

        guard case .failed(.other) = outcome else {
            Issue.record("expected a failure without an active account")
            return
        }
    }

    @Test func missingSetupErrorsMapToTheInvitePathOnTheDirectChatRoute() {
        #expect(
            StartChatFailurePresentation.failure(
                for: MarmotKitError.MissingKeyPackage(account: alice, reason: .notFound)
            ) == .missingSetup
        )
        #expect(
            StartChatFailurePresentation.failure(
                for: MarmotKitError.InvalidKeyPackageEvent(details: "stale")
            ) == .missingSetup
        )
        #expect(
            StartChatFailurePresentation.failure(
                for: MarmotKitError.InvalidIdentity(details: "unusable")
            ) == .missingSetup
        )
    }

    @Test func otherErrorsStayRetryableErrors() {
        let failure = StartChatFailurePresentation.failure(
            for: MarmotKitError.NotGroupAdmin(groupIdHex: "abc")
        )

        guard case .other = failure else {
            Issue.record("unexpected invite mapping for an unrelated error")
            return
        }
    }

    @Test func outdatedKeyPackagesAndIncompleteLookupsStayRetryableErrors() {
        for error in [
            MarmotKitError.MissingKeyPackage(account: alice, reason: .obsoleteOnly),
            MarmotKitError.DirectoryLookupIncomplete(account: alice)
        ] {
            #expect(StartChatFailurePresentation.failure(for: error)
                == .other(message: UserFacingError.message(for: error)))
        }
    }

    @Test func runtimeKeyPackageAndConnectivityFailuresStayRetryable() {
        for (details, expected) in [("recipient KeyPackage incompatible", "Recipient KeyPackage incompatible"), ("relay disconnected", "Relay disconnected")] {
            #expect(StartChatFailurePresentation.failure(
                for: MarmotKitError.Runtime(details: details)
            ) == .other(message: expected))
        }
    }

    @Test func inviteCopyUsesTheKnownNameOrAGenericFallback() {
        let named = StartChatFailurePresentation.inviteDetail(recipientName: "Alice")
        let generic = StartChatFailurePresentation.inviteDetail(recipientName: nil)
        let blank = StartChatFailurePresentation.inviteDetail(recipientName: "")

        #expect(named.contains("Alice"))
        #expect(!generic.isEmpty)
        #expect(generic == blank)
        #expect(StartChatFailurePresentation.inviteMessage().contains("https://"))
    }

    @Test func promptKindFollowsTheFailureTaxonomy() {
        #expect(StartChatPrompt.kind(for: .missingSetup) == .invite)
        #expect(StartChatPrompt.kind(for: .other(message: "boom")) == .error(message: "boom"))
    }

    private enum TestError: Error {
        case unexpectedCreate
    }
}

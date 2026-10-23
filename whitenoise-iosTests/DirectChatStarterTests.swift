import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
@Suite(.tags(.runtime))
struct DirectChatStarterTests {
    private let alice = String(repeating: "bb", count: 32)

    @Test func reopensAnExistingDirectChatWithoutCreating() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let starter = DirectChatStarter()
        starter.createGroupForTesting = { _, _ in
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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let starter = DirectChatStarter()
        var observedRefs: [String] = []
        starter.createGroupForTesting = { accountRef, memberRef in
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
        store.record(accountRef: "first", row: chatRow(id: "old"))
        store.record(accountRef: "first", row: chatRow(id: "new"))

        #expect(store.row(accountRef: "first", groupIdHex: "old") == nil)
        #expect(store.row(accountRef: "first", groupIdHex: "new")?.title == "new")
        #expect(store.row(accountRef: "second", groupIdHex: "new") == nil)

        store.record(accountRef: "second", row: chatRow(id: "other"))
        #expect(store.row(accountRef: "first", groupIdHex: "new") == nil)
        #expect(store.row(accountRef: "second", groupIdHex: "other")?.title == "other")
    }

    @Test func secondTapIsIgnoredWhileTheFirstCreateIsInFlight() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account"
        let starter = DirectChatStarter()
        let gate = (entered: TestLatch(), released: TestLatch())
        starter.createGroupForTesting = { _, _ in
            gate.entered.signal()
            try? await gate.released.wait()
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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = nil
        let starter = DirectChatStarter()

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
                for: MarmotKitError.MissingKeyPackage(account: alice)
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

    private func chatRow(id: String) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: id,
            pinned: false,
            pinnedPosition: nil,
            archived: false,
            pendingConfirmation: false,
            title: id,
            groupName: id,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            manuallyMarkedUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1,
            activitySortAt: 1,
            updatedAt: 1,
            selfMembership: .member,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil
        )
    }

    private enum TestError: Error {
        case unexpectedCreate
    }
}

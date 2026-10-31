import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct SupportChatTests {
    @Test func canonicalSupportContactResolvesToAUsableRecipient() throws {
        #expect(WhiteNoiseSupportContact.npub.hasPrefix("npub1"))
        let recipient = try #require(WhiteNoiseSupportContact.recipient)
        #expect(recipient.memberRef == WhiteNoiseSupportContact.npub)
        #expect(recipient.accountIdHex.count == 64)
    }

    @Test func existingSupportChatOpensWithoutCreatingADuplicate() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: "existing-support-dm") { _, _ in
            Issue.record("must not create a duplicate support chat")
            return "unexpected"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIdHex: String?

        await model.start(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(openedGroupIdHex == "existing-support-dm")
        #expect(model.phase == .routing)
    }

    @Test func missingSupportChatCreatesThroughTheNormalDirectChatPath() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        var createdAccountRef: String?
        var createdMemberRef: String?
        let flow = testFlow(existingGroupIdHex: nil) { accountRef, memberRef in
            createdAccountRef = accountRef
            createdMemberRef = memberRef
            return "new-support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIdHex: String?

        await model.start(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(createdAccountRef == "active")
        #expect(createdMemberRef == WhiteNoiseSupportContact.npub)
        #expect(openedGroupIdHex == "new-support-dm")
        #expect(model.phase == .routing)
    }

    @Test func openingSupportAgainReusesTheConversation() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: "existing-support-dm") { _, _ in
            Issue.record("reopening support must reuse the existing conversation")
            return "unexpected"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIds: [String] = []

        await model.start(using: appState) { openedGroupIds.append($0) }
        // A second tap during the handoff must not start another operation.
        await model.start(using: appState) { openedGroupIds.append($0) }
        #expect(openedGroupIds == ["existing-support-dm"])

        // Opening Support again creates a fresh screen after returning to Settings.
        let reopenedModel = SupportChatViewModel(chatFlow: flow)
        await reopenedModel.start(using: appState) { openedGroupIds.append($0) }

        #expect(openedGroupIds == ["existing-support-dm", "existing-support-dm"])
        #expect(reopenedModel.phase == .routing)
    }

    @Test func discardedRoutingCanReopenTheCompletedConversation() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        var creations = 0
        let marmot = NewChatFlowMarmotDouble()
        let flow = testFlow(existingGroupIdHex: nil, marmot: marmot) { _, _ in
            creations += 1
            return "created-support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        await model.start(using: appState) { _ in }
        #expect(model.phase == .routing)

        // The view rejects navigation if the runtime changes during destination preparation.
        model.resetRouting()
        #expect(model.phase == .idle)
        marmot.existingDirectChat = { _, _ in "created-support-dm" }
        var openedGroupId: String?
        await model.start(using: appState) { openedGroupId = $0 }

        #expect(openedGroupId == "created-support-dm")
        #expect(creations == 1)
        #expect(model.phase == .routing)
    }

    @Test func supportChatFailureIsRecoverableWithoutSurfacingEngineCopy() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        var attempt = 0
        let flow = testFlow(existingGroupIdHex: nil) { _, _ in
            attempt += 1
            if attempt == 1 {
                throw TestFailure.sensitiveEngineDetail
            }
            return "retried-support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIdHex: String?

        await model.start(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(model.phase == .failed)
        guard case .error(let internalMessage) = flow.startPrompt?.kind else {
            Issue.record("expected the normal retryable direct-chat prompt")
            return
        }
        #expect(!internalMessage.isEmpty)
        #expect(SupportChatPresentation.failureTitle != internalMessage)
        #expect(!SupportChatPresentation.failureMessage.contains(internalMessage))

        await model.retry(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(openedGroupIdHex == "retried-support-dm")
        #expect(model.phase == .routing)
    }

    @Test func failedExistingChatLookupNeverCreatesADuplicate() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        var didCreate = false
        let marmot = NewChatFlowMarmotDouble()
        let flow = newChatFlow(starter: directChatStarter { _, _ in
            didCreate = true
            return "duplicate-support-dm"
        }, marmot: marmot)
        var lookupAttempt = 0
        marmot.existingDirectChat = { _, _ in
            lookupAttempt += 1
            if lookupAttempt == 1 {
                throw TestFailure.existingChatLookupFailed
            }
            return "existing-support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIdHex: String?

        await model.start(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(model.phase == .failed)
        #expect(!didCreate)

        await model.retry(using: appState) {
            openedGroupIdHex = $0
        }

        #expect(lookupAttempt == 2)
        #expect(openedGroupIdHex == "existing-support-dm")
        #expect(!didCreate)
    }

    @Test func directChatLookupUsesTypedConversationKindAndActiveMembership() {
        #expect(DirectChatReuseLookup.shouldInspect(
            conversationKind: .direct,
            selfMembership: .member
        ))
        #expect(DirectChatReuseLookup.shouldInspect(
            conversationKind: .unknown,
            selfMembership: .member
        ))
        #expect(!DirectChatReuseLookup.shouldInspect(
            conversationKind: .group,
            selfMembership: .member
        ))
        #expect(!DirectChatReuseLookup.shouldInspect(
            conversationKind: .direct,
            selfMembership: .left
        ))
    }

    @Test func directChatLookupReusesTheNewestExactDirectConversation() {
        let myAccountIdHex = String(repeating: "a", count: 64)
        let targetAccountIdHex = String(repeating: "b", count: 64)
        let older = directChatSnapshot(
            groupIdHex: "older",
            conversationKind: .direct,
            lastActivityAt: 10,
            members: [myAccountIdHex, targetAccountIdHex]
        )
        let newer = directChatSnapshot(
            groupIdHex: "newer",
            conversationKind: .direct,
            lastActivityAt: 20,
            members: [targetAccountIdHex, myAccountIdHex]
        )
        let twoPersonGroup = directChatSnapshot(
            groupIdHex: "not-a-dm",
            conversationKind: .group,
            lastActivityAt: 30,
            members: [myAccountIdHex, targetAccountIdHex]
        )

        let result = DirectChatReuseLookup.existingGroupId(
            in: [older, newer, twoPersonGroup],
            targetAccountIdHex: targetAccountIdHex,
            myAccountIdHex: myAccountIdHex
        )

        #expect(result == "newer")
    }

    @Test func supportChatReportsLoadingWhileCreationIsInFlight() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let gate = (entered: TestLatch(), released: TestLatch())
        let flow = testFlow(existingGroupIdHex: nil) { _, _ in
            gate.entered.signal()
            await gate.released.hold()
            return "support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)

        let task = Task {
            await model.start(using: appState) { _ in }
        }
        try await gate.entered.wait()

        #expect(model.phase == .loading)
        #expect(model.isCreatingChat)

        gate.released.signal()
        await task.value
        #expect(model.phase == .routing)
    }

    @Test func cancellingWhileLookingForAnExistingChatDoesNotCreateOne() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        var didCreate = false
        let marmot = NewChatFlowMarmotDouble()
        let flow = newChatFlow(starter: directChatStarter { _, _ in
            didCreate = true
            return "unexpected"
        }, marmot: marmot)
        let gate = (entered: TestLatch(), released: TestLatch())
        marmot.existingDirectChat = { _, _ in
            gate.entered.signal()
            await gate.released.hold()
            return nil
        }
        let model = SupportChatViewModel(chatFlow: flow)

        let task = Task {
            await model.start(using: appState) { _ in }
        }
        try await gate.entered.wait()
        task.cancel()
        gate.released.signal()
        await task.value

        #expect(!didCreate)
        #expect(model.phase == .idle)
    }

    @Test(arguments: [false, true])
    func cancelledCreationDoesNotOpenSupportButCanBeReopened(isRetry: Bool) async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let gate = (entered: TestLatch(), released: TestLatch())
        var creationCompleted = false
        var creations = 0
        // A retry first needs a failed creation to retry.
        let failedCreations = isRetry ? 1 : 0
        let marmot = NewChatFlowMarmotDouble()
        let flow = testFlow(existingGroupIdHex: nil, marmot: marmot) { _, _ in
            creations += 1
            if creations <= failedCreations {
                throw TestFailure.sensitiveEngineDetail
            }
            guard creations == failedCreations + 1 else {
                Issue.record("a later Start Chat must reuse the completed conversation")
                return "unexpected"
            }
            // Like the native operation, this completion can arrive after cancellation.
            gate.entered.signal()
            await gate.released.hold()
            creationCompleted = true
            return "created-support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIds: [String] = []

        if isRetry {
            await model.start(using: appState) { openedGroupIds.append($0) }
            #expect(model.phase == .failed)
        }

        let task = Task {
            if isRetry {
                await model.retry(using: appState) { openedGroupIds.append($0) }
            } else {
                await model.start(using: appState) { openedGroupIds.append($0) }
            }
        }
        try await gate.entered.wait()
        task.cancel()
        gate.released.signal()
        await task.value

        #expect(creationCompleted)
        #expect(openedGroupIds.isEmpty)
        #expect(model.phase == .idle)

        marmot.existingDirectChat = { _, _ in "created-support-dm" }
        await model.start(using: appState) { openedGroupIds.append($0) }
        #expect(openedGroupIds == ["created-support-dm"])
        #expect(model.phase == .routing)
    }

    @Test(arguments: [false, true])
    func settingsEntryOnlyLooksUpSupport(hasExistingChat: Bool) async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: hasExistingChat ? "support-dm" : nil) { _, _ in
            Issue.record("opening the Settings entry must never create a conversation")
            return "unexpected"
        }
        let entry = SupportChatEntryModel(chatFlow: flow)

        await entry.prepare(using: appState)

        let destination = try #require(entry.destination)
        #expect(destination.chatTarget?.groupIdHex == (hasExistingChat ? "support-dm" : nil))
        #expect(!entry.isLoading)
        #expect(!entry.showsFailure)
    }

    @Test func settingsKeepsProgressVisibleUntilTheDestinationIsPrepared() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let entry = SupportChatEntryModel(chatFlow: testFlow(existingGroupIdHex: "support-dm"))
        let gate = (entered: TestLatch(), released: TestLatch())
        let task = Task {
            await entry.prepare(using: appState) { _ in gate.entered.signal(); await gate.released.hold() }
        }
        try await gate.entered.wait()
        #expect(entry.isLoading)
        #expect(entry.destination == nil)

        gate.released.signal()
        await task.value
        #expect(entry.destination?.chatTarget?.groupIdHex == "support-dm")
        #expect(!entry.isLoading)
    }

    @Test(arguments: [false, true])
    func settingsDiscardsAPreparedDestinationAfterLeavingOrSwitchingAccount(switchAccount: Bool) async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let entry = SupportChatEntryModel(chatFlow: testFlow(existingGroupIdHex: "support-dm"))
        let gate = (entered: TestLatch(), released: TestLatch())
        let task = Task {
            await entry.prepare(using: appState) { _ in gate.entered.signal(); await gate.released.hold() }
        }
        try await gate.entered.wait()
        if switchAccount { appState.activeAccountRef = "replacement" }
        else { task.cancel() }
        gate.released.signal()
        await task.value

        #expect(entry.destination == nil)
        #expect(!entry.isLoading)
        #expect(!entry.showsFailure)
    }

    @Test func settingsLookupFailureOffersRetryWithoutShowingStartChat() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let marmot = NewChatFlowMarmotDouble()
        let flow = newChatFlow(marmot: marmot)
        var attempt = 0
        marmot.existingDirectChat = { _, _ in
            attempt += 1
            if attempt == 1 { throw TestFailure.existingChatLookupFailed }
            return "support-dm"
        }
        let entry = SupportChatEntryModel(chatFlow: flow)

        await entry.prepare(using: appState)
        #expect(entry.showsFailure)
        #expect(entry.destination == nil)

        await entry.prepare(using: appState)
        #expect(!entry.showsFailure)
        #expect(entry.destination?.chatTarget?.groupIdHex == "support-dm")
    }

    @Test func cancelledSettingsLookupDoesNotNavigateAndCanBeRetried() async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "active"
        let marmot = NewChatFlowMarmotDouble()
        let flow = newChatFlow(marmot: marmot)
        let gate = (entered: TestLatch(), released: TestLatch())
        var lookups = 0
        marmot.existingDirectChat = { _, _ in
            lookups += 1
            gate.entered.signal()
            await gate.released.hold()
            return "support-dm"
        }
        let entry = SupportChatEntryModel(chatFlow: flow)
        let task = Task { await entry.prepare(using: appState) }
        try await gate.entered.wait()
        #expect(entry.isLoading)
        await entry.prepare(using: appState)
        #expect(lookups == 1)

        task.cancel()
        gate.released.signal()
        await task.value
        #expect(entry.destination == nil)
        #expect(!entry.showsFailure)
        #expect(!entry.isLoading)

        marmot.existingDirectChat = { _, _ in "support-dm" }
        await entry.prepare(using: appState)
        #expect(entry.destination?.chatTarget?.groupIdHex == "support-dm")
    }

    @Test(arguments: [false, true])
    func settingsLookupDiscardsResultsAfterAccountChange(lookupFails: Bool) async throws {
        let appState = AppState.test()
        appState.activeAccountRef = "original"
        let marmot = NewChatFlowMarmotDouble()
        let flow = newChatFlow(marmot: marmot)
        let gate = (entered: TestLatch(), released: TestLatch())
        marmot.existingDirectChat = { _, _ in
            gate.entered.signal()
            await gate.released.hold()
            if lookupFails { throw TestFailure.existingChatLookupFailed }
            return "original-account-support-dm"
        }
        let entry = SupportChatEntryModel(chatFlow: flow)
        let task = Task { await entry.prepare(using: appState) }
        try await gate.entered.wait()
        appState.activeAccountRef = "replacement"
        gate.released.signal()
        await task.value

        #expect(entry.destination == nil)
        #expect(!entry.showsFailure)
        #expect(!entry.isLoading)
    }

    /// A flow whose existing-chat lookup finds `existingGroupIdHex`. Pass
    /// `marmot` to change the lookup later in the test.
    private func testFlow(
        existingGroupIdHex: String?,
        marmot: NewChatFlowMarmotDouble? = nil,
        create: @escaping @MainActor (_ accountRef: String, _ memberRef: String) async throws -> String = { _, _ in
            Issue.record("this flow must not create a conversation")
            return "unexpected"
        }
    ) -> NewChatFlowViewModel {
        let marmot = marmot ?? NewChatFlowMarmotDouble()
        marmot.existingDirectChat = { _, _ in existingGroupIdHex }
        return newChatFlow(starter: directChatStarter(create: create), marmot: marmot)
    }

    private func directChatSnapshot(
        groupIdHex: String,
        conversationKind: ChatConversationKindFfi,
        lastActivityAt: UInt64,
        members: [String]
    ) -> RecipientGroupSnapshot {
        RecipientGroupSnapshot(
            groupIdHex: groupIdHex,
            sanitizedName: nil,
            title: "Direct chat",
            avatarUrl: nil,
            isSelfMember: true,
            conversationKind: conversationKind,
            lastActivityAt: lastActivityAt,
            memberIdsHex: members,
            lastSenderIdHex: nil,
            welcomerIdHex: nil
        )
    }

    private enum TestFailure: Error {
        case sensitiveEngineDetail
        case existingChatLookupFailed
    }
}

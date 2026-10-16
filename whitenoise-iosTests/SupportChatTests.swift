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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: "existing-support-dm")
        flow.starter.createGroupForTesting = { _, _ in
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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: nil)
        var createdAccountRef: String?
        var createdMemberRef: String?
        flow.starter.createGroupForTesting = { accountRef, memberRef in
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

    @Test func returningFromSupportConversationAllowsOpeningItAgain() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: "existing-support-dm")
        flow.starter.createGroupForTesting = { _, _ in
            Issue.record("reopening support must reuse the existing conversation")
            return "unexpected"
        }
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIds: [String] = []

        await model.start(using: appState) { openedGroupIds.append($0) }
        // A second tap during the handoff must not start another operation.
        await model.start(using: appState) { openedGroupIds.append($0) }
        #expect(openedGroupIds == ["existing-support-dm"])

        model.finishRouting()
        await model.start(using: appState) { openedGroupIds.append($0) }

        #expect(openedGroupIds == ["existing-support-dm", "existing-support-dm"])
        #expect(model.phase == .routing)
    }

    @Test func supportChatFailureIsRecoverableWithoutSurfacingEngineCopy() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: nil)
        var attempt = 0
        flow.starter.createGroupForTesting = { _, _ in
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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = NewChatFlowViewModel()
        var lookupAttempt = 0
        flow.existingDirectChatGroupIdForTesting = { _ in
            lookupAttempt += 1
            if lookupAttempt == 1 {
                throw TestFailure.existingChatLookupFailed
            }
            return "existing-support-dm"
        }
        var didCreate = false
        flow.starter.createGroupForTesting = { _, _ in
            didCreate = true
            return "duplicate-support-dm"
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
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: nil)
        let gate = SupportChatCreateGate()
        flow.starter.createGroupForTesting = { _, _ in
            await gate.hold()
            return "support-dm"
        }
        let model = SupportChatViewModel(chatFlow: flow)

        let task = Task {
            await model.start(using: appState) { _ in }
        }
        await gate.waitUntilHeld()

        #expect(model.phase == .loading)
        #expect(model.isCreatingChat)

        await gate.release()
        await task.value
        #expect(model.phase == .routing)
    }

    @Test func cancellingWhileLookingForAnExistingChatDoesNotCreateOne() async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = NewChatFlowViewModel()
        let gate = SupportChatCreateGate()
        flow.existingDirectChatGroupIdForTesting = { _ in
            await gate.hold()
            return nil
        }
        var didCreate = false
        flow.starter.createGroupForTesting = { _, _ in
            didCreate = true
            return "unexpected"
        }
        let model = SupportChatViewModel(chatFlow: flow)

        let task = Task {
            await model.start(using: appState) { _ in }
        }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release()
        await task.value

        #expect(!didCreate)
        #expect(model.phase == .idle)
    }

    @Test(arguments: [false, true])
    func cancelledCreationDoesNotOpenSupportButCanBeReopened(isRetry: Bool) async throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "active"
        let flow = testFlow(existingGroupIdHex: nil)
        let model = SupportChatViewModel(chatFlow: flow)
        var openedGroupIds: [String] = []

        if isRetry {
            flow.starter.createGroupForTesting = { _, _ in throw TestFailure.sensitiveEngineDetail }
            await model.start(using: appState) { openedGroupIds.append($0) }
            #expect(model.phase == .failed)
        }

        let gate = SupportChatCreateGate()
        var creationCompleted = false
        flow.starter.createGroupForTesting = { _, _ in
            // Like the native operation, this completion can arrive after cancellation.
            await gate.hold()
            creationCompleted = true
            return "created-support-dm"
        }
        let task = Task {
            if isRetry {
                await model.retry(using: appState) { openedGroupIds.append($0) }
            } else {
                await model.start(using: appState) { openedGroupIds.append($0) }
            }
        }
        await gate.waitUntilHeld()
        task.cancel()
        await gate.release()
        await task.value

        #expect(creationCompleted)
        #expect(openedGroupIds.isEmpty)
        #expect(model.phase == .idle)

        flow.existingDirectChatGroupIdForTesting = { _ in "created-support-dm" }
        flow.starter.createGroupForTesting = { _, _ in
            Issue.record("a later Start Chat must reuse the completed conversation")
            return "unexpected"
        }
        await model.start(using: appState) { openedGroupIds.append($0) }
        #expect(openedGroupIds == ["created-support-dm"])
        #expect(model.phase == .routing)
    }

    private func testFlow(existingGroupIdHex: String?) -> NewChatFlowViewModel {
        let flow = NewChatFlowViewModel()
        flow.existingDirectChatGroupIdForTesting = { _ in existingGroupIdHex }
        return flow
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

private actor SupportChatCreateGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

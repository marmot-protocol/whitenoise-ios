import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// Tap-to-bubble behaviour for outgoing messages: the local row is rendered
/// before draft persistence and MDK, and is reconciled with MDK's authoritative
/// row without duplicating, dropping or reordering it.
@MainActor
struct OutgoingSendResponsivenessTests {

    // MARK: - Follow-latest command suppression

    @Test func stayingOnTheLiveTailNeedsNoReturnToLatestCommand() {
        #expect(!ConversationLatestIntent.needsLatestCommand(
            hasWindow: true, intent: .followingLatest, hasMoreAfter: false,
            pendingAnchorIntent: nil, navigationFailed: false))
    }

    @Test func anythingOffTheLiveTailStillIssuesReturnToLatest() {
        // Scrolled into history.
        #expect(ConversationLatestIntent.needsLatestCommand(
            hasWindow: true, intent: .history("anchor"), hasMoreAfter: false,
            pendingAnchorIntent: nil, navigationFailed: false))
        // Newer messages sit outside the loaded window.
        #expect(ConversationLatestIntent.needsLatestCommand(
            hasWindow: true, intent: .followingLatest, hasMoreAfter: true,
            pendingAnchorIntent: nil, navigationFailed: false))
        // An anchor command is still queued.
        #expect(ConversationLatestIntent.needsLatestCommand(
            hasWindow: true, intent: .followingLatest, hasMoreAfter: false,
            pendingAnchorIntent: "anchor", navigationFailed: false))
        // A previous latest/jump failed, so the intent is not in force.
        #expect(ConversationLatestIntent.needsLatestCommand(
            hasWindow: true, intent: .followingLatest, hasMoreAfter: false,
            pendingAnchorIntent: nil, navigationFailed: true))
        // No window open yet: the intent still has to be issued.
        #expect(ConversationLatestIntent.needsLatestCommand(
            hasWindow: false, intent: .followingLatest, hasMoreAfter: false,
            pendingAnchorIntent: nil, navigationFailed: false))
    }

    @Test func aSendOnTheLiveTailDoesNotDependOnAFollowLatestCommand() throws {
        let harness = try SendHarness()
        harness.installWindow([])
        // No conversation window is installed in this harness, so a follow-latest
        // request would be issued rather than skipped — the bubble must be up
        // before it is asked for either way.
        let staged = try #require(harness.composer.stage(text: "on the tail"))
        harness.viewModel.followConversationLatest()

        #expect(harness.rowIDs == ["msg:\(staged.tempId)"])
        #expect(harness.statuses == [.sending])
    }

    // MARK: - Staging

    @Test func sendTapParksItsBubbleBeforeAnyAwait() throws {
        let harness = try SendHarness()
        harness.installWindow([])

        let staged = try #require(harness.composer.stage(text: "  hello  "))

        // No await ran between the tap and this assertion.
        #expect(harness.rowIDs == ["msg:\(staged.tempId)"])
        #expect(harness.store.localSendPhase(rowID: "msg:\(staged.tempId)") == .pending)
        #expect(harness.plaintexts == ["hello"])
    }

    @Test func aBlockedDraftSaveStillShowsTheBubbleAndSettlesItAsFailed() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let gate = AsyncGate()

        let staged = try #require(harness.composer.stage(text: "waiting on the draft store"))
        #expect(harness.rowIDs.count == 1)

        let submission = Task { @MainActor in
            await gate.wait()
            harness.viewModel.failStagedSend(staged)
        }
        // The bubble is up while the "draft save" is still blocked.
        #expect(harness.rowIDs == ["msg:\(staged.tempId)"])
        #expect(harness.statuses == [.sending])
        gate.open()
        await submission.value
        #expect(harness.statuses == [.failed])
        #expect(harness.store.failedTransientRecord(rowId: "msg:\(staged.tempId)") != nil)
        try await harness.shutdown()
    }

    @Test func aBlockedPublicationKeepsTheBubbleVisible() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let gate = AsyncGate()
        harness.composer.sendTextForTesting = { _, _, _, _, token in
            await gate.wait()
            return accepted("a", token: token)
        }

        let send = Task { @MainActor in await harness.composer.send("still publishing") }
        await Task.yield()
        #expect(harness.rowIDs.count == 1)
        #expect(harness.statuses == [.sending])
        gate.open()
        await send.value
        #expect(harness.rowIDs.count == 1)
        try await harness.shutdown()
    }

    // MARK: - Reconciliation

    @Test func aProjectionArrivingBeforeTheSendResponseReusesTheSameRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let gate = AsyncGate()
        harness.composer.sendTextForTesting = { _, _, _, _, token in
            // MDK commits its pending row before this call returns.
            harness.installWindow([harness.ownRecord(id: hexId(1), text: "hi", timelineAt: 10, delivered: false, token: token)])
            await gate.wait()
            return accepted(hexId(1), token: token)
        }

        let send = Task { @MainActor in await harness.composer.send("hi") }
        while harness.store.protocolID(forDisplayID: harness.rowIDs.first ?? "") == nil, !send.isCancelled {
            await Task.yield()
        }
        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.rowIDs == [rowID])
        #expect(harness.store.protocolID(forDisplayID: rowID) == hexId(1))
        #expect(harness.statuses == [.sending])

        gate.open()
        await send.value
        #expect(harness.rowIDs == [rowID])
        harness.installWindow([harness.ownRecord(id: hexId(1), text: "hi", timelineAt: 10, delivered: true, token: String(rowID.dropFirst(4)))])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.statuses == [.sent])
        try await harness.shutdown()
    }

    @Test func aProjectionArrivingAfterAcceptanceReusesTheSameRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in accepted(hexId(2), token: token) }
        let staged = try #require(harness.composer.stage(text: "hi"))
        await harness.composer.submit(staged)
        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.store.protocolID(forDisplayID: rowID) == nil)
        #expect(harness.statuses == [.sending])
        harness.installWindow([harness.ownRecord(id: hexId(2), text: "hi", timelineAt: 11,
            delivered: true, token: staged.clientToken)])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.statuses == [.sent])
        try await harness.shutdown()
    }

    @Test func identicalBackToBackSendsProduceOneRowEach() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in accepted("unused", token: token) }

        let first = try #require(harness.composer.stage(text: "same"))
        let second = try #require(harness.composer.stage(text: "same"))
        harness.store.markLocalSendSubmitted(tempId: first.tempId)
        harness.store.markLocalSendSubmitted(tempId: second.tempId)

        harness.installWindow([
            harness.ownRecord(id: hexId(3), text: "same", timelineAt: 20, delivered: false, token: first.clientToken),
            harness.ownRecord(id: hexId(4), text: "same", timelineAt: 21, delivered: false, token: second.clientToken),
        ])

        #expect(harness.rowIDs == ["msg:\(first.tempId)", "msg:\(second.tempId)"])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(first.tempId)") == hexId(3))
        #expect(harness.store.protocolID(forDisplayID: "msg:\(second.tempId)") == hexId(4))
        try await harness.shutdown()
    }

    @Test func exactTokensDisambiguateIdenticalSendsInReverseOrder() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let first = try #require(harness.composer.stage(text: "same"))
        let second = try #require(harness.composer.stage(text: "same"))
        harness.store.markLocalSendSubmitted(tempId: first.tempId)
        harness.store.markLocalSendSubmitted(tempId: second.tempId)
        harness.installWindow([harness.ownRecord(id: hexId(5), text: "same", timelineAt: 20,
            delivered: false, token: second.clientToken)])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(second.tempId)") == hexId(5))
        #expect(harness.store.protocolID(forDisplayID: "msg:\(first.tempId)") == nil)
        #expect(harness.rowIDs.count == 2)
        try await harness.shutdown()
    }

    @Test func aSubmittedBubbleNeverClaimsAnotherDevicesTokenlessRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let staged = try #require(harness.composer.stage(text: "same"))
        harness.store.markLocalSendSubmitted(tempId: staged.tempId)

        harness.installWindow([harness.ownRecord(id: hexId(6), text: "same", timelineAt: 30, delivered: true)])

        #expect(harness.store.protocolID(forDisplayID: "msg:\(staged.tempId)") == nil)
        #expect(harness.rowIDs == ["msg:\(hexId(6))", "msg:\(staged.tempId)"])
        try await harness.shutdown()
    }

    @Test func aReplyBubbleOnlyClaimsARowWithTheSameParent() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let parent = hexId(7)
        let staged = try #require(harness.composer.stage(text: "answer", replyTargetId: parent))
        harness.store.markLocalSendSubmitted(tempId: staged.tempId)

        var unrelated = harness.ownRecord(id: hexId(8), text: "answer", timelineAt: 40, delivered: false)
        unrelated.replyToMessageIdHex = nil
        harness.installWindow([unrelated])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(staged.tempId)") == nil)

        var reply = harness.ownRecord(id: hexId(9), text: "answer", timelineAt: 41, delivered: false)
        reply.replyToMessageIdHex = parent
        reply.clientToken = staged.clientToken
        harness.installWindow([unrelated, reply])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(staged.tempId)") == hexId(9))
        try await harness.shutdown()
    }

    @Test func anAttachmentBubbleKeepsItsPickedBytesUntilTheDurableRowArrives() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let attachment = MessageMediaAttachment(id: "local", reference: nil, fileName: "local.jpg",
            mediaType: "image/jpeg", dim: nil, localData: Data([1, 2, 3]))
        let rowID = "msg:photo"
        harness.store.mediaProjections.setPending([attachment], forRowId: rowID)
        harness.store.applyPendingOutgoingMessage(tempId: "photo", record: harness.optimisticRecord(text: "caption"))
        harness.store.markLocalSendSubmitted(tempId: "photo")
        #expect(harness.rowIDs == [rowID])

        // A text row with the same caption must not consume the media bubble.
        harness.installWindow([harness.ownRecord(id: hexId(10), text: "caption", timelineAt: 50, delivered: false)])
        #expect(harness.store.protocolID(forDisplayID: rowID) == nil)
        #expect(harness.store.mediaProjections.pending(forRowId: rowID)?.count == 1)
        try await harness.shutdown()
    }

    @Test func anAmbiguousCompletionKeepsTheBubbleClaimableRatherThanFailed() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in throw MarmotKitError.AccountWorkerResponseTimedOut }

        await harness.composer.send("maybe landed")
        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.store.localSendPhase(rowID: rowID) == .completionUnknown)
        #expect(harness.store.failedTransientRecord(rowId: rowID) == nil)

        harness.installWindow([harness.ownRecord(id: hexId(11), text: "maybe landed", timelineAt: 60, delivered: true, token: String(rowID.dropFirst(4)))])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.store.protocolID(forDisplayID: rowID) == hexId(11))
        try await harness.shutdown()
    }

    @Test func aDefinitiveFailureCannotPaintOverAnAlreadyProjectedRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in
            harness.installWindow([harness.ownRecord(id: hexId(12), text: "landed", timelineAt: 70, delivered: false, token: token)])
            throw MarmotKitError.Runtime(details: "relay disconnected")
        }

        await harness.composer.send("landed")

        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.rowIDs == [rowID])
        #expect(harness.statuses == [.sending])
        #expect(harness.store.failedTransientRecord(rowId: rowID) == nil)
        try await harness.shutdown()
    }

    @Test func aConversationResetDuringPreparationRetiresTheStagedSend() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in
            Issue.record("A retired conversation must not reach the SDK")
            return accepted("unused", token: token)
        }
        let staged = try #require(harness.composer.stage(text: "leaving"))
        #expect(harness.rowIDs.count == 1)

        harness.store.resetOptimisticState()
        await harness.composer.submit(staged)

        #expect(harness.rowIDs.isEmpty)
        try await harness.shutdown()
    }

    @Test func anAccountSwitchDuringPreparationRetiresTheStagedSend() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _, token in
            Issue.record("A retired account must not reach the SDK")
            return accepted("unused", token: token)
        }
        let staged = try #require(harness.composer.stage(text: "switching"))

        harness.appState.activeAccountRef = "another-account"
        var accepted: Bool?
        await harness.composer.submit(staged) { accepted = $0 }

        #expect(accepted == false)
        try await harness.shutdown()
    }
}

// MARK: - Helpers

@MainActor
private final class SendHarness {
    let client: MarmotClient
    let appState: AppState
    let viewModel: ConversationViewModel
    let store: TimelineStore
    let composer: ComposerModel

    init() throws {
        client = try MarmotClient.testClient()
        appState = AppState(client: client)
        appState.activeAccountRef = "account-ref"
        viewModel = ConversationViewModel(appState: appState, group: harnessGroup())
        store = viewModel.timelineStore
        composer = viewModel.composer
        composer.canSendMessages = { true }
        composer.localSendStatusForTesting = { _ in nil }
        composer.canSendMediaAttachments = { true }
    }

    var rowIDs: [String] { store.timeline.map(\.id) }

    var statuses: [MessageStatus] {
        store.timeline.compactMap { if case .message(_, let status) = $0.kind { return status } else { return nil } }
    }

    var plaintexts: [String] {
        store.timeline.compactMap { if case .message(let record, _) = $0.kind { return record.plaintext } else { return nil } }
    }

    /// Drives the prepared conversation-window path, which is what a live chat uses.
    func installWindow(_ records: [TimelineMessageRecordFfi]) {
        store.applyConversationWindowPage(
            TimelinePageFfi(messages: records, hasMoreBefore: false, hasMoreAfter: false)
        )
    }

    func ownRecord(id: String, text: String, timelineAt: UInt64, delivered: Bool, token: String? = nil) -> TimelineMessageRecordFfi {
        var record = TimelineMessageRecordFfi(
            messageIdHex: id, sourceMessageIdHex: delivered ? id : nil, direction: "sent",
            groupIdHex: harnessGroupId, sender: "", plaintext: text,
            contentTokens: .emptyDocument, kind: MessageSemantics.kindChat, tags: [],
            timelineAt: timelineAt, receivedAt: timelineAt, replyToMessageIdHex: nil, replyPreview: nil,
            mediaJson: nil, media: [], agentTextStreamJson: nil, groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil,
            deleted: false, deletedByMessageIdHex: nil, invalidationStatus: nil
        )
        record.clientToken = token
        return record
    }

    func optimisticRecord(text: String) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: "", direction: "sent", groupIdHex: harnessGroupId, sender: "",
            plaintext: text, kind: MessageSemantics.kindChat, tags: [], recordedAt: 1, receivedAt: 1
        )
    }

    func shutdown() async throws {
        try await client.marmot.shutdownAndClose()
    }
}

private extension StagedOutgoingSend {
    var recordForTesting: AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: "", direction: "sent", groupIdHex: harnessGroupId, sender: "",
            plaintext: text, kind: MessageSemantics.kindChat, tags: [], recordedAt: 1, receivedAt: 1
        )
    }
}

/// A latch a test can hold a send behind.
// NSLock guards all mutable state; the compiler cannot verify that synchronization.
// swiftlint:disable:next no_unchecked_sendable
private final class AsyncGate: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(); return }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuations
        continuations = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private func accepted(_ id: String, token: String) -> LocalSendAcceptanceFfi {
    LocalSendAcceptanceFfi(clientToken: token, messageIdHex: id)
}

private func hexId(_ n: Int) -> String { String(format: "%064x", n) }

private let harnessGroupId = String(repeating: "c", count: 64)

private func harnessGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: harnessGroupId, endpoint: "", name: "Harness", description: "",
        admins: [], relays: [], nostrGroupIdHex: "", avatarUrl: nil, avatarDim: nil, avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008, component: "marmot.group.encrypted-media.v1", required: true,
            mediaFormat: EncryptedMediaVersionFfi.v1.wireValue, allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")]
        ),
        archived: false, pendingConfirmation: false, welcomerAccountIdHex: nil, viaWelcomeMessageIdHex: nil
    )
}

import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// Tap-to-bubble behaviour for outgoing messages: the local row is rendered
/// before draft persistence and MDK, and is reconciled with MDK's authoritative
/// row without duplicating, dropping or reordering it.
@MainActor
struct OutgoingSendResponsivenessTests {

    // MARK: - Correlation policy (pure)

    @Test func identicalConsecutiveSendsClaimProjectedRowsInSendOrder() {
        let shared = fingerprint(text: "same")
        let candidates = [
            LocalSendCandidate(rowID: "msg:b", order: 2, fingerprint: shared),
            LocalSendCandidate(rowID: "msg:a", order: 1, fingerprint: shared),
        ]
        #expect(OutgoingSendCorrelation.claimant(for: shared, candidates: candidates) == "msg:a")
        #expect(OutgoingSendCorrelation.claimant(
            for: shared,
            candidates: candidates.filter { $0.rowID != "msg:a" }
        ) == "msg:b")
    }

    @Test func aRowNoLocalSendMatchesIsLeftAlone() {
        let candidates = [LocalSendCandidate(rowID: "msg:a", order: 1, fingerprint: fingerprint(text: "mine"))]
        #expect(OutgoingSendCorrelation.claimant(for: fingerprint(text: "other device"), candidates: candidates) == nil)
        #expect(OutgoingSendCorrelation.claimant(
            for: fingerprint(text: "mine", replyTargetId: "parent"), candidates: candidates) == nil)
        #expect(OutgoingSendCorrelation.claimant(
            for: fingerprint(text: "mine", isMedia: true), candidates: candidates) == nil)
    }

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
        harness.composer.sendTextForTesting = { _, _, _, _ in
            await gate.wait()
            return published(["a"])
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
        harness.composer.sendTextForTesting = { _, _, _, _ in
            // MDK commits its pending row before this call returns.
            harness.installWindow([harness.ownRecord(id: hexId(1), text: "hi", timelineAt: 10, delivered: false)])
            await gate.wait()
            return published([hexId(1)])
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
        harness.installWindow([harness.ownRecord(id: hexId(1), text: "hi", timelineAt: 10, delivered: true)])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.statuses == [.sent])
        try await harness.shutdown()
    }

    @Test func aProjectionArrivingAfterTheSendResponseReusesTheSameRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _ in published([hexId(2)]) }

        await harness.composer.send("hi")
        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.store.protocolID(forDisplayID: rowID) == hexId(2))

        harness.installWindow([harness.ownRecord(id: hexId(2), text: "hi", timelineAt: 11, delivered: true)])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.statuses == [.sent])
        try await harness.shutdown()
    }

    @Test func identicalBackToBackSendsProduceOneRowEach() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _ in published([]) }

        let first = try #require(harness.composer.stage(text: "same"))
        let second = try #require(harness.composer.stage(text: "same"))
        harness.store.markLocalSendSubmitted(tempId: first.tempId)
        harness.store.markLocalSendSubmitted(tempId: second.tempId)

        harness.installWindow([
            harness.ownRecord(id: hexId(3), text: "same", timelineAt: 20, delivered: false),
            harness.ownRecord(id: hexId(4), text: "same", timelineAt: 21, delivered: false),
        ])

        #expect(harness.rowIDs == ["msg:\(first.tempId)", "msg:\(second.tempId)"])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(first.tempId)") == hexId(3))
        #expect(harness.store.protocolID(forDisplayID: "msg:\(second.tempId)") == hexId(4))
        try await harness.shutdown()
    }

    @Test func anExactSendIdRebindsASpeculativeClaimWithoutDuplicating() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let first = try #require(harness.composer.stage(text: "same"))
        let second = try #require(harness.composer.stage(text: "same"))
        harness.store.markLocalSendSubmitted(tempId: first.tempId)
        harness.store.markLocalSendSubmitted(tempId: second.tempId)
        harness.installWindow([harness.ownRecord(id: hexId(5), text: "same", timelineAt: 20, delivered: false)])
        #expect(harness.store.protocolID(forDisplayID: "msg:\(first.tempId)") == hexId(5))

        // MDK committed the rows in the other order: the exact id wins.
        harness.store.confirmSent(tempId: second.tempId, record: first.recordForTesting, messageId: hexId(5))

        #expect(harness.store.protocolID(forDisplayID: "msg:\(second.tempId)") == hexId(5))
        #expect(harness.store.protocolID(forDisplayID: "msg:\(first.tempId)") == nil)
        // Neither bubble is duplicated or dropped: the durable row moved to the
        // id the send response named, and the other keeps its own local row.
        #expect(Set(harness.rowIDs) == ["msg:\(first.tempId)", "msg:\(second.tempId)"])
        #expect(harness.rowIDs.count == 2)
        try await harness.shutdown()
    }

    @Test func anUnsubmittedBubbleNeverClaimsAnotherDevicesRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        let staged = try #require(harness.composer.stage(text: "same"))

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
        harness.composer.sendTextForTesting = { _, _, _, _ in throw MarmotKitError.AccountWorkerResponseTimedOut }

        await harness.composer.send("maybe landed")
        let rowID = try #require(harness.rowIDs.first)
        #expect(harness.store.localSendPhase(rowID: rowID) == .completionUnknown)
        #expect(harness.store.failedTransientRecord(rowId: rowID) == nil)

        harness.installWindow([harness.ownRecord(id: hexId(11), text: "maybe landed", timelineAt: 60, delivered: true)])
        #expect(harness.rowIDs == [rowID])
        #expect(harness.store.protocolID(forDisplayID: rowID) == hexId(11))
        try await harness.shutdown()
    }

    @Test func aDefinitiveFailureCannotPaintOverAnAlreadyProjectedRow() async throws {
        let harness = try SendHarness()
        harness.installWindow([])
        harness.composer.sendTextForTesting = { _, _, _, _ in
            harness.installWindow([harness.ownRecord(id: hexId(12), text: "landed", timelineAt: 70, delivered: false)])
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
        harness.composer.sendTextForTesting = { _, _, _, _ in
            Issue.record("A retired conversation must not reach the SDK")
            return published([])
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
        harness.composer.sendTextForTesting = { _, _, _, _ in
            Issue.record("A retired account must not reach the SDK")
            return published([])
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

    func ownRecord(id: String, text: String, timelineAt: UInt64, delivered: Bool) -> TimelineMessageRecordFfi {
        TimelineMessageRecordFfi(
            messageIdHex: id, sourceMessageIdHex: delivered ? id : nil, direction: "sent",
            groupIdHex: harnessGroupId, sender: "", plaintext: text,
            contentTokens: .emptyDocument, kind: MessageSemantics.kindChat, tags: [],
            timelineAt: timelineAt, receivedAt: timelineAt, replyToMessageIdHex: nil, replyPreview: nil,
            mediaJson: nil, media: [], agentTextStreamJson: nil, groupSystem: nil,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil,
            deleted: false, deletedByMessageIdHex: nil, invalidationStatus: nil
        )
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

private func published(_ ids: [String]) -> SendSummaryFfi {
    SendSummaryFfi(published: 1, messageIds: ids, acceptDisposition: .published, maintenanceDisposition: .ready)
}

private func fingerprint(text: String, replyTargetId: String? = nil, isMedia: Bool = false) -> LocalSendFingerprint {
    LocalSendFingerprint(
        groupIdHex: harnessGroupId, sender: "me", plaintext: text,
        kind: MessageSemantics.kindChat, replyTargetId: replyTargetId, isMedia: isMedia
    )
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

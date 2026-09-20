import Foundation
import Observation
import MarmotKit

nonisolated struct VerifiedMediaUploadAttachment {
    let data: Data
    let reference: MediaAttachmentReferenceFfi
}

nonisolated enum MediaUploadIntegrity {
    static func verifiedAttachments(
        plaintexts: [Data],
        references: [MediaAttachmentReferenceFfi]
    ) async -> [VerifiedMediaUploadAttachment] {
        var verified: [VerifiedMediaUploadAttachment] = []
        for (data, reference) in zip(plaintexts, references) {
            guard await MediaPlaintextHash.matches(
                data,
                expectedSha256: reference.plaintextSha256
            ) else {
                continue
            }
            verified.append(VerifiedMediaUploadAttachment(data: data, reference: reference))
        }
        return verified
    }
}

nonisolated enum SendAcceptanceAction: Equatable {
    case confirmPublished(messageId: String?)
    case awaitDurableProjection
}

nonisolated enum SendAcceptancePolicy {
    static func action(for summary: SendSummaryFfi) -> SendAcceptanceAction {
        switch summary.acceptDisposition {
        case .published:
            return .confirmPublished(messageId: summary.messageIds.first)
        case .acceptedPending, .completionUnknown:
            return .awaitDurableProjection
        }
    }
}

nonisolated enum SendFailurePolicy {
    static func awaitsDurableState(error: Error, submittedDraft: Bool) -> Bool {
        // Revision tokens are opaque; an error cannot prove the draft was not consumed.
        submittedDraft || error is CancellationError
            || (error as? MarmotKitError)?.isAccountWorkerResponseTimedOut == true
    }
}

/// One outgoing message already parked in the timeline, waiting for its draft
/// revision and its trip to MDK. Everything the send publishes is captured at
/// the Send tap, so a composer edit afterwards belongs to the next message.
@MainActor
struct StagedOutgoingSend {
    let tempId: String
    let accountRef: String
    let lifetime: UUID
    let replyTargetId: String?
    let text: String
    let attachments: [MediaDraftAttachment]
    let uploadEpoch: Int
    fileprivate let record: AppMessageRecordFfi
    fileprivate let contentTokens: Task<MarkdownDocumentFfi, Never>
}

/// Owns the conversation composer's send pipeline: the reply target and the
/// text/media send FFI orchestration. Optimistic rows are handed to
/// `TimelineStore` (the overlay is timeline-mirror state, not composer state);
/// the group-derived send gates are injected as closures so the composer holds
/// no group roster. Carved out of `ConversationViewModel` (Phase 5b).
///
/// Sending is two-phase: `stage` parks the bubble synchronously at the tap, and
/// `submit` publishes it behind `sendQueue`. Nothing blocks the Send button for
/// the round-trip, so rapid consecutive sends each get their bubble at once.
@Observable
@MainActor
final class ComposerModel {
    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi? {
        didSet {
            restoredReplyTargetMessageIdHex = nil
        }
    }
    private var restoredReplyTargetMessageIdHex: String?
    var replyTargetMessageIdHex: String? {
        if let messageIdHex = replyingTo?.messageIdHex, !messageIdHex.isEmpty {
            return messageIdHex
        }
        return restoredReplyTargetMessageIdHex
    }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private unowned let timelineStore: TimelineStore
    @ObservationIgnored private let sendQueue = OutgoingSendQueue()
    @ObservationIgnored var canSendMessages: () -> Bool = { false }
    @ObservationIgnored var canSendMediaAttachments: () -> Bool = { false }
    /// Surfaces a send failure to the view model (sets its observable `error`).
    @ObservationIgnored var onError: (String) -> Void = { _ in }
#if DEBUG
    @ObservationIgnored var sendTextForTesting:
        ((String, String, String?, String) async throws -> SendSummaryFfi)?
#endif

    init(appState: AppState?, groupIdHex: String, timelineStore: TimelineStore) {
        self.appState = appState
        self.groupIdHex = groupIdHex
        self.timelineStore = timelineStore
    }

    func restoreReplyTarget(messageIdHex: String?, record: AppMessageRecordFfi?) {
        replyingTo = record
        if record == nil {
            restoredReplyTargetMessageIdHex = Hex.normalized32Bytes(messageIdHex)
        }
    }

    /// Re-sends a failed text message from its retained optimistic record.
    /// Reuses the local display identity while creating a new send attempt.
    /// Media sends are only discarded here. Returns false when the row isn't a
    /// retryable failed text send.
    @discardableResult
    func retryFailedTextSend(rowId: String) async -> Bool {
        guard let record = timelineStore.failedTransientRecord(rowId: rowId),
              !timelineStore.failedTransientRowHasStagedMedia(rowId: rowId),
              record.tags.allSatisfy({ $0.values.first != "_media_pending" }),
              !record.plaintext.isEmpty
        else { return false }
        // Keep the failed row when the device is offline — a retry would fail
        // straight back into the same state and read as the button doing
        // nothing. Say why instead.
        guard MediaAutoDownloadStore.shared.isOnline else {
            onError(L10n.string("You're offline. Try again once you're connected."))
            return false
        }
        // A retry usually follows a connectivity change, and relay recovery
        // is otherwise tied to app-foreground activation — pump the account
        // workers first (what foregrounding does), then wait out any runtime
        // warm-up before re-sending into the same failure it just left.
        if let appState, let client = try? appState.currentMarmotClient() {
            try? await client.catchUpAccounts()
        }
        var waited = 0
        while let appState, appState.isRuntimeWarmingUp, waited < 10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        // The row is the only copy of the user's message — never discard it
        // unless the send below is actually going to run, and re-check the
        // row itself: the awaits above are wide enough for a second retry or
        // a Delete to have consumed it already.
        guard timelineStore.failedTransientRecord(rowId: rowId) != nil else { return false }
        guard canSendMessages() else {
            onError(L10n.string("Send failed"))
            return false
        }
        let replyTargetId = ConversationViewModel.replyTargetMessageId(in: record)
        await send(record.plaintext, replyTargetId: replyTargetId, retryTempId: String(rowId.dropFirst("msg:".count)))
        return true
    }

    /// Parks the message in the timeline synchronously, at the Send tap. No
    /// await runs before the bubble exists, so draft persistence, markdown
    /// parsing and MDK are all off the path to first paint. The submitted text,
    /// reply target and attachments are captured here, so later composer edits
    /// cannot change what publishes.
    func stage(
        text: String,
        attachments: [MediaDraftAttachment] = [],
        replyTargetId overrideReplyTargetId: String? = nil,
        retryTempId: String? = nil
    ) -> StagedOutgoingSend? {
        guard let appState, let accountRef = appState.activeAccountRef else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Defense-in-depth: clamp to the protocol's max length so an oversized
        // paste can't bypass the composer's cap (#54).
        let outgoing = trimmed.isEmpty ? "" : ConversationViewModel.cappedOutgoingText(trimmed)
        if attachments.isEmpty {
            guard !outgoing.isEmpty, canSendMessages() else { return nil }
        } else {
            guard canSendMediaAttachments() else { return nil }
        }

        let tempId = retryTempId ?? UUID().uuidString
        let rowID = "msg:\(tempId)"
        // A media send carries its caption, never a reply target.
        let replyTargetId = attachments.isEmpty ? (overrideReplyTargetId ?? replyTargetMessageId()) : nil
        let now = UInt64(Date().timeIntervalSince1970)
        // A reply is a kind-9 with `e` + `q` tags pointing at the parent; a plain
        // message is a bare kind-9.
        let optimisticTags: [MessageTagFfi] = replyTargetId.map {
            [
                MessageTagFfi(values: [MessageSemantics.eventRefTag, $0]),
                MessageTagFfi(values: [MessageSemantics.quoteRefTag, $0]),
            ]
        } ?? []
        // Staged with no parsed tokens: `displayBlocks` returns nil for an empty
        // document and the bubble renders its plain-text path until the
        // off-MainActor parse upgrades the row (#226 kept the parse off the UI
        // thread; this also keeps it off the path to first paint).
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: outgoing,
            contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat,
            tags: optimisticTags,
            recordedAt: now,
            receivedAt: now
        )
        // Measured from the tap, so tap-to-draft-ready is inside the window.
        timelineStore.beginMessageVisibility(rowID: rowID, operation: .outboundMessageVisible)
        if !attachments.isEmpty {
            timelineStore.mediaProjections.setPending(attachments.map(\.displayItem), forRowId: rowID)
        }
        timelineStore.applyPendingOutgoingMessage(tempId: tempId, record: record)
        replyingTo = nil

        let contentTokens = Task { @MainActor [weak timelineStore] () -> MarkdownDocumentFfi in
            guard !outgoing.isEmpty else { return .emptyDocument }
            let parsed = await appState.parseMarkdown(text: outgoing)
            timelineStore?.upgradePendingOutgoingTokens(tempId: tempId, contentTokens: parsed)
            return parsed
        }
        return StagedOutgoingSend(
            tempId: tempId,
            accountRef: accountRef,
            lifetime: timelineStore.outgoingLifetime,
            replyTargetId: replyTargetId,
            text: outgoing,
            attachments: attachments,
            // Captured before the upload round-trip: a wipe completing while the
            // send is in flight must invalidate the post-upload cache store.
            uploadEpoch: MessageMediaCache.currentProducerEpoch(),
            record: record,
            contentTokens: contentTokens
        )
    }

    /// Publishes an already-staged send. Runs behind `sendQueue`, so back-to-back
    /// sends reach the relays in the order Send was pressed.
    func submit(
        _ staged: StagedOutgoingSend,
        draftRevision: MessageDraftRevisionFfi? = nil,
        completion: (@MainActor (Bool) async -> Void)? = nil
    ) async {
        guard let appState else { await completion?(false); return }
        if staged.attachments.isEmpty {
            await submitText(staged, appState: appState, draftRevision: draftRevision, completion: completion)
        } else {
            await submitMedia(staged, appState: appState, draftRevision: draftRevision, completion: completion)
        }
    }

    /// Stage-and-submit for sends with no draft revision behind them (Giphy,
    /// shared location, failed-send retry).
    func send(_ text: String, draftRevision: MessageDraftRevisionFfi? = nil,
              completion: (@MainActor (Bool) async -> Void)? = nil) async {
        await send(text, replyTargetId: nil, draftRevision: draftRevision, completion: completion)
    }

    private func send(_ text: String, replyTargetId overrideReplyTargetId: String?, retryTempId: String? = nil,
                      draftRevision: MessageDraftRevisionFfi? = nil,
                      completion: (@MainActor (Bool) async -> Void)? = nil) async {
        guard let staged = stage(text: text, replyTargetId: overrideReplyTargetId, retryTempId: retryTempId) else {
            await completion?(false)
            return
        }
        await submit(staged, draftRevision: draftRevision, completion: completion)
    }

    private func submitText(
        _ staged: StagedOutgoingSend,
        appState: AppState,
        draftRevision: MessageDraftRevisionFfi?,
        completion: (@MainActor (Bool) async -> Void)?
    ) async {
        await sendQueue.enqueue { [self] in
            guard timelineStore.outgoingLifetime == staged.lifetime,
                  appState.activeAccountRef == staged.accountRef else {
                await completion?(false)
                return
            }
            var optimistic = staged.record
            optimistic.contentTokens = await staged.contentTokens.value
            guard timelineStore.outgoingLifetime == staged.lifetime,
                  appState.activeAccountRef == staged.accountRef else {
                await completion?(false)
                return
            }
            let submission = appState.productAnalytics.beginTiming()
            do {
                timelineStore.markLocalSendSubmitted(tempId: staged.tempId)
                let summary = try await sendText(
                    appState: appState,
                    accountRef: staged.accountRef,
                    replyTargetId: staged.replyTargetId,
                    text: staged.text,
                    draftRevision: draftRevision
                )
                appState.productAnalytics.recordTiming(.sendSubmission, since: submission)
                await completion?(true)
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else { return }
                timelineStore.acceptSend(tempId: staged.tempId, record: optimistic, summary: summary)
            } catch {
                appState.productAnalytics.recordTiming(.sendSubmission, since: submission, outcome: .failure)
                let ambiguous = SendFailurePolicy.awaitsDurableState(
                    error: error, submittedDraft: draftRevision != nil)
                // Refresh the selected revision after uncertain admission before releasing draft writes.
                await completion?(ambiguous)
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else { return }
                if ambiguous {
                    timelineStore.markSendCompletionUnknown(tempId: staged.tempId)
                    onError(UserFacingError.message(for: error))
                    return
                }
                timelineStore.markFailed(tempId: staged.tempId)
                onError(UserFacingError.message(for: error))
                Haptics.error()
                appState.present(UserFacingError.toast(title: L10n.string("Send failed"), error: error))
            }
        }.value
    }

    private func sendText(
        appState: AppState,
        accountRef: String,
        replyTargetId: String?,
        text: String,
        draftRevision: MessageDraftRevisionFfi?
    ) async throws -> SendSummaryFfi {
#if DEBUG
        if let sendTextForTesting {
            return try await sendTextForTesting(accountRef, groupIdHex, replyTargetId, text)
        }
#endif
        let client = try appState.currentMarmotClient()
        if let draftRevision {
            return try await client.sendMessageDraft(accountRef: accountRef, revision: draftRevision, attachments: [])
        }
        if let replyTargetId {
            return try await client.replyToMessage(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                targetMessageId: replyTargetId,
                text: text
            )
        }
        return try await client.sendText(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            text: text
        )
    }

    func sendMedia(_ attachments: [MediaDraftAttachment], caption: String,
                   draftRevision: MessageDraftRevisionFfi? = nil,
                   completion: (@MainActor (Bool) async -> Void)? = nil) async {
        guard let staged = stage(text: caption, attachments: attachments) else {
            await completion?(false)
            return
        }
        await submit(staged, draftRevision: draftRevision, completion: completion)
    }

    private func submitMedia(
        _ staged: StagedOutgoingSend,
        appState: AppState,
        draftRevision: MessageDraftRevisionFfi?,
        completion: (@MainActor (Bool) async -> Void)?
    ) async {
        await sendQueue.enqueue { [self] in
            guard timelineStore.outgoingLifetime == staged.lifetime,
                  appState.activeAccountRef == staged.accountRef else {
                await completion?(false)
                return
            }
            let captionTokens = await staged.contentTokens.value
            var submittedDraft = false
            let submission = appState.productAnalytics.beginTiming()
            do {
                let client = try appState.currentMarmotClient()
                // An unsent-draft upload publishes the message itself, so MDK can
                // project this row before the call returns: claim from here on.
                timelineStore.markLocalSendSubmitted(tempId: staged.tempId)
                let result = try await client.uploadMedia(
                    accountRef: staged.accountRef,
                    groupIdHex: groupIdHex,
                    request: MediaUploadRequestFfi(
                        attachments: staged.attachments.map(\.uploadRequest),
                        caption: staged.text.isEmpty ? nil : staged.text,
                        send: draftRevision == nil,
                        blossomServer: nil
                    )
                )
                let verifiedAttachments = await MediaUploadIntegrity.verifiedAttachments(
                    plaintexts: staged.attachments.map(\.data),
                    references: result.attachments.map(\.reference)
                )
                let references = verifiedAttachments.map(\.reference)
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else {
                    await completion?(false)
                    return
                }
                let sent: SendSummaryFfi?
                if let draftRevision {
                    submittedDraft = true
                    sent = try await client.sendMessageDraft(accountRef: staged.accountRef, revision: draftRevision, attachments: references)
                } else {
                    // The upload itself published when `send` was set.
                    sent = result.sent
                }
                appState.productAnalytics.recordTiming(.sendSubmission, since: submission)
                await completion?(true)
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else { return }
                for attachment in verifiedAttachments {
                    await MessageMediaCache.store(
                        attachment.data,
                        for: attachment.reference,
                        producerGeneration: staged.uploadEpoch
                    )
                }
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else { return }
                let confirmed = AppMessageRecordFfi(
                    messageIdHex: "",
                    direction: "sent",
                    groupIdHex: groupIdHex,
                    sender: staged.record.sender,
                    plaintext: staged.text,
                    contentTokens: captionTokens,
                    kind: MessageSemantics.kindChat,
                    tags: references.map(MessageSemantics.imetaTag(for:)),
                    recordedAt: staged.record.recordedAt,
                    receivedAt: staged.record.receivedAt
                )
                if let sent {
                    timelineStore.acceptSend(tempId: staged.tempId, record: confirmed, summary: sent)
                    if let id = sent.messageIds.first, !id.isEmpty,
                       timelineStore.replaceMediaReferences(references, forMessageId: id) {
                        timelineStore.noteProjectionChanged()
                    }
                } else {
                    timelineStore.markSendCompletionUnknown(tempId: staged.tempId)
                }
            } catch {
                appState.productAnalytics.recordTiming(.sendSubmission, since: submission, outcome: .failure)
                let ambiguous = SendFailurePolicy.awaitsDurableState(
                    error: error, submittedDraft: submittedDraft)
                // Refresh the selected revision after uncertain admission before releasing draft writes.
                await completion?(ambiguous)
                guard timelineStore.outgoingLifetime == staged.lifetime,
                      appState.activeAccountRef == staged.accountRef else { return }
                if ambiguous {
                    timelineStore.markSendCompletionUnknown(tempId: staged.tempId)
                    onError(UserFacingError.message(for: error))
                    return
                }
                timelineStore.markFailed(tempId: staged.tempId)
                onError(UserFacingError.message(for: error))
                Haptics.error()
                appState.present(UserFacingError.toast(title: L10n.string("Send failed"), error: error))
            }
        }.value
    }

    private func replyTargetMessageId() -> String? {
        replyTargetMessageIdHex
    }
}

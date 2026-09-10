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

/// Owns the conversation composer's send pipeline: the in-flight send guard, the
/// reply target, and the text/media send FFI orchestration. Optimistic rows are
/// handed to `TimelineStore` (the overlay is timeline-mirror state, not composer
/// state); the group-derived send gates are injected as closures so the composer
/// holds no group roster. Carved out of `ConversationViewModel` (Phase 5b).
@Observable
@MainActor
final class ComposerModel {
    private(set) var sendInFlight = false
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
    /// The failed row is discarded first so the retry produces a single fresh
    /// pending row; media sends are not retried here (their compressed bytes
    /// aren't retained), only discarded. Returns false when the row isn't a
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
        guard !sendInFlight, canSendMessages() else {
            onError(L10n.string("Send failed"))
            return false
        }
        let replyTargetId = ConversationViewModel.replyTargetMessageId(in: record)
        timelineStore.discardTransientRow(rowId: rowId)
        await send(record.plaintext, replyTargetId: replyTargetId)
        return true
    }

    func send(_ text: String) async {
        await send(text, replyTargetId: nil)
    }

    private func send(_ text: String, replyTargetId overrideReplyTargetId: String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sendInFlight,
              canSendMessages(),
              !trimmed.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        // Defense-in-depth: clamp to the protocol's max length so an oversized
        // paste can't bypass the composer's cap (#54).
        let outgoing = ConversationViewModel.cappedOutgoingText(trimmed)

        // Claim the send slot before the first suspension point. The off-MainActor
        // markdown parse below introduces an `await`, so leaving the flag unset
        // would let a second send task start during a long parse (#226 review).
        sendInFlight = true

        let replyTargetId = overrideReplyTargetId ?? replyTargetMessageId()
        let tempId = UUID().uuidString
        timelineStore.beginMessageVisibility(rowID: "msg:\(tempId)", operation: .outboundMessageVisible)
        let now = UInt64(Date().timeIntervalSince1970)
        // A reply is a kind-9 with `e` + `q` tags pointing at the parent; a plain
        // message is a bare kind-9.
        let optimisticTags: [MessageTagFfi] = replyTargetId.map {
            [
                MessageTagFfi(values: [MessageSemantics.eventRefTag, $0]),
                MessageTagFfi(values: [MessageSemantics.quoteRefTag, $0]),
            ]
        } ?? []
        // Parse markdown off the MainActor: `parseMarkdown` is a synchronous
        // rustCall whose cost scales with message length, so building the
        // optimistic record inline would stall the composer at send time (#226).
        let contentTokens = await appState.parseMarkdown(text: outgoing)
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: outgoing,
            contentTokens: contentTokens,
            kind: MessageSemantics.kindChat,
            tags: optimisticTags,
            recordedAt: now,
            receivedAt: now
        )
        timelineStore.applyPendingOutgoingMessage(tempId: tempId, record: optimistic)
        replyingTo = nil
        // The composer is free the moment the message is parked in the
        // timeline: the round-trip below waits in `sendQueue`, not on the
        // Send button (#226 blocked the button for its whole duration).
        sendInFlight = false

        await sendQueue.enqueue { [self] in
            do {
                let summary = try await sendText(
                    appState: appState,
                    accountRef: accountRef,
                    replyTargetId: replyTargetId,
                    text: outgoing
                )
                switch SendAcceptancePolicy.action(for: summary) {
                case .confirmPublished(let messageId):
                    timelineStore.confirmSent(tempId: tempId, record: optimistic, messageId: messageId)
                case .awaitDurableProjection:
                    // Marmot retained the exact event for durable delivery. Keep the
                    // optimistic row sending until the timeline projection supplies
                    // the pending row and eventual disposition.
                    break
                }
            } catch {
                timelineStore.markFailed(tempId: tempId)
                onError(error.localizedDescription)
                await MainActor.run {
                    Haptics.error()
                    appState.present(UserFacingError.toast(title: L10n.string("Send failed"), error: error))
                }
            }
        }.value
    }

    private func sendText(
        appState: AppState,
        accountRef: String,
        replyTargetId: String?,
        text: String
    ) async throws -> SendSummaryFfi {
#if DEBUG
        if let sendTextForTesting {
            return try await sendTextForTesting(accountRef, groupIdHex, replyTargetId, text)
        }
#endif
        let client = try appState.currentMarmotClient()
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

    func sendMedia(_ attachments: [MediaDraftAttachment], caption: String) async {
        guard !sendInFlight,
              !attachments.isEmpty,
              canSendMediaAttachments(),
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingCaption = trimmedCaption.isEmpty ? "" : ConversationViewModel.cappedOutgoingText(trimmedCaption)
        let captionForRust = outgoingCaption.isEmpty ? nil : outgoingCaption
        let tempId = UUID().uuidString
        timelineStore.beginMessageVisibility(rowID: "msg:\(tempId)", operation: .outboundMessageVisible)
        let tempRowId = "msg:\(tempId)"
        let now = UInt64(Date().timeIntervalSince1970)

        // Claim the send slot before the first suspension point. The off-MainActor
        // caption parse below introduces an `await`, so leaving the flag unset
        // would let a second send task start during a long parse (#226 review).
        sendInFlight = true

        // Captured before the upload round-trip: a wipe completing while the
        // send is in flight must invalidate the post-upload cache store.
        let uploadEpoch = MessageMediaCache.currentProducerEpoch()

        let captionTokens: MarkdownDocumentFfi = outgoingCaption.isEmpty
            ? .emptyDocument
            : await appState.parseMarkdown(text: outgoingCaption)
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: outgoingCaption,
            contentTokens: captionTokens,
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: now,
            receivedAt: now
        )
        timelineStore.mediaProjections.setPending(attachments.map(\.displayItem), forRowId: tempRowId)
        timelineStore.applyPendingOutgoingMessage(tempId: tempId, record: optimistic)
        replyingTo = nil
        // Freed at hand-off, like a text send: the upload and publish below
        // belong to the parked row's bubble, not to the Send button.
        sendInFlight = false

        await sendQueue.enqueue { [self] in
            do {
                let client = try appState.currentMarmotClient()
                let result = try await client.uploadMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    request: MediaUploadRequestFfi(
                        attachments: attachments.map(\.uploadRequest),
                        caption: captionForRust,
                        send: true,
                        blossomServer: nil
                    )
                )
                let verifiedAttachments = await MediaUploadIntegrity.verifiedAttachments(
                    plaintexts: attachments.map(\.data),
                    references: result.attachments.map(\.reference)
                )
                let references = verifiedAttachments.map(\.reference)
                for attachment in verifiedAttachments {
                    await MessageMediaCache.store(
                        attachment.data,
                        for: attachment.reference,
                        producerGeneration: uploadEpoch
                    )
                }
                let confirmed = AppMessageRecordFfi(
                    messageIdHex: "",
                    direction: "sent",
                    groupIdHex: groupIdHex,
                    sender: optimistic.sender,
                    plaintext: outgoingCaption,
                    contentTokens: captionTokens,
                    kind: MessageSemantics.kindChat,
                    tags: references.map(MessageSemantics.imetaTag(for:)),
                    recordedAt: now,
                    receivedAt: now
                )
                if let sent = result.sent,
                   case .awaitDurableProjection = SendAcceptancePolicy.action(for: sent) {
                    // Keep the staged media and optimistic row alive until Marmot's
                    // durable pending projection replaces them.
                } else {
                    let messageId: String?
                    if let sent = result.sent,
                       case .confirmPublished(let publishedMessageId) = SendAcceptancePolicy.action(for: sent) {
                        messageId = publishedMessageId
                    } else {
                        messageId = nil
                    }
                    timelineStore.confirmSent(tempId: tempId, record: confirmed, messageId: messageId)
                    if let messageId, !messageId.isEmpty {
                        // Render the just-sent attachments immediately from the upload's
                        // resolved references; the subscription row will mirror the same.
                        if timelineStore.replaceMediaReferences(references, forMessageId: messageId) {
                            timelineStore.noteProjectionChanged()
                        }
                    }
                }
            } catch {
                timelineStore.markFailed(tempId: tempId)
                onError(error.localizedDescription)
                await MainActor.run {
                    Haptics.error()
                    appState.present(UserFacingError.toast(title: L10n.string("Send failed"), error: error))
                }
            }
        }.value
    }

    private func replyTargetMessageId() -> String? {
        replyTargetMessageIdHex
    }
}

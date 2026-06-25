import Foundation
import Observation
import MarmotKit

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
    var replyingTo: AppMessageRecordFfi?

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private let groupIdHex: String
    @ObservationIgnored private unowned let timelineStore: TimelineStore
    @ObservationIgnored var canSendMessages: () -> Bool = { false }
    @ObservationIgnored var canSendMediaAttachments: () -> Bool = { false }
    /// Surfaces a send failure to the view model (sets its observable `error`).
    @ObservationIgnored var onError: (String) -> Void = { _ in }

    init(appState: AppState?, groupIdHex: String, timelineStore: TimelineStore) {
        self.appState = appState
        self.groupIdHex = groupIdHex
        self.timelineStore = timelineStore
    }

    func send(_ text: String) async {
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
        defer { sendInFlight = false }

        let replyTargetId = replyTargetMessageId()
        let tempId = UUID().uuidString
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

        do {
            let client = try appState.currentMarmotClient()
            let summary: SendSummaryFfi
            if let replyTargetId {
                summary = try await client.replyToMessage(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    targetMessageId: replyTargetId,
                    text: outgoing
                )
            } else {
                summary = try await client.sendText(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    text: outgoing
                )
            }
            timelineStore.confirmSent(tempId: tempId, record: optimistic, messageId: summary.messageIds.first)
        } catch {
            timelineStore.markFailed(tempId: tempId)
            onError(error.localizedDescription)
            await MainActor.run {
                Haptics.error()
                appState.present(.error(L10n.string("Send failed"), message: error.localizedDescription))
            }
        }
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
        let tempRowId = "msg:\(tempId)"
        let now = UInt64(Date().timeIntervalSince1970)

        // Claim the send slot before the first suspension point. The off-MainActor
        // caption parse below introduces an `await`, so leaving the flag unset
        // would let a second send task start during a long parse (#226 review).
        sendInFlight = true
        defer { sendInFlight = false }

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
            let references = result.attachments.map(\.reference)
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
            let messageId = result.sent?.messageIds.first
            timelineStore.confirmSent(tempId: tempId, record: confirmed, messageId: messageId)
            if let messageId, !messageId.isEmpty {
                // Render the just-sent attachments immediately from the upload's
                // resolved references; the subscription row will mirror the same.
                if timelineStore.replaceMediaReferences(references, forMessageId: messageId) {
                    timelineStore.noteProjectionChanged()
                }
            }
        } catch {
            timelineStore.markFailed(tempId: tempId)
            onError(error.localizedDescription)
            await MainActor.run {
                Haptics.error()
                appState.present(.error(L10n.string("Send failed"), message: error.localizedDescription))
            }
        }
    }

    private func replyTargetMessageId() -> String? {
        guard let replyingTo, !replyingTo.messageIdHex.isEmpty else { return nil }
        return replyingTo.messageIdHex
    }
}

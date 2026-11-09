import Foundation
import MarmotKit
import Observation

/// Sends custom emoji messages and reactions for one conversation.
///
/// Every send is bound to the account, runtime and chat it started in: after
/// each await the scope is re-read, and a changed scope cancels the send
/// before anything reaches MDK, so a late upload can never publish into
/// another conversation. Uploaded references live in `uploads` and are reused
/// on retry, so a failed send never uploads the same image again while its
/// epoch is current.
@MainActor
final class ConversationCustomEmojiSender {
    typealias SendMessage = @MainActor (_ scope: CustomEmojiScope, _ caption: String,
                                        _ attachments: [MediaAttachmentReferenceFfi], _ tags: [[String]]) async throws -> Void
    typealias SendReaction = @MainActor (_ scope: CustomEmojiScope, _ targetMessageId: String, _ emoji: String,
                                         _ attachments: [MediaAttachmentReferenceFfi], _ tags: [[String]]) async throws -> Void

    let uploads: CustomEmojiUploadCache
    private let scopeProvider: @MainActor () -> CustomEmojiScope?
    private let currentEpoch: @MainActor () -> UInt64?
    private let sendMessageOperation: SendMessage
    private let sendReactionOperation: SendReaction

    init(
        scopeProvider: @escaping @MainActor () -> CustomEmojiScope?,
        currentEpoch: @escaping @MainActor () -> UInt64?,
        loadBytes: @escaping CustomEmojiUploadCache.LoadBytes,
        readInstalled: @escaping CustomEmojiUploadCache.ReadInstalled,
        upload: @escaping CustomEmojiUploadCache.Upload,
        sendMessage: @escaping SendMessage,
        sendReaction: @escaping SendReaction = { _, _, _, _, _ in throw CancellationError() }
    ) {
        self.scopeProvider = scopeProvider
        self.currentEpoch = currentEpoch
        self.sendMessageOperation = sendMessage
        self.sendReactionOperation = sendReaction
        self.uploads = CustomEmojiUploadCache(scopeProvider: scopeProvider, loadBytes: loadBytes,
                                              readInstalled: readInstalled, upload: upload)
    }

    /// Sends `text` as a kind-9 whose attachments are the `emoji` images, in
    /// text order, each named by an `emoji` tag; a reply adds `e` + `q`.
    /// Throws `CustomEmojiSendError`, or `CancellationError` when the scope
    /// changed (nothing was sent).
    @discardableResult
    func sendMessage(text: String, replyTargetId: String?, emoji: [CustomEmojiSendable]) async throws -> [CustomEmojiUploadCache.Uploaded] {
        guard let scope = scopeProvider() else { throw CancellationError() }
        guard !emoji.isEmpty else { throw CustomEmojiSendError.malformedTag }
        try CustomEmojiTags.precheck(emojiCount: emoji.count, isReply: replyTargetId != nil)
        if let replyTargetId {
            try CustomEmojiTags.validate([[MessageSemantics.eventRefTag, replyTargetId]])
        }
        let uploaded = try await upload(emoji, scope: scope)
        let tags = try CustomEmojiTags.messageTags(
            emoji: zip(emoji, uploaded).map { ($0.shortcode, $1.reference) },
            replyTargetId: replyTargetId
        )
        try ensure(scope)
        // Shortcode aliases of one image share an upload: one attachment, one
        // `emoji` tag each.
        var seen = Set<MediaAttachmentReferenceFfi>()
        let references = uploaded.map(\.reference).filter { seen.insert($0).inserted }
        do {
            try await sendMessageOperation(scope, text, references, tags)
        } catch {
            throw classify(error, references: references)
        }
        return uploaded
    }

    /// Reacts to `targetMessageId` with one custom emoji: a kind-7 whose
    /// content is `:shortcode:`, carrying the image re-encrypted for the
    /// current epoch and named by one `emoji` tag. Reuses an upload the
    /// emoji already has, so a retry never uploads it again.
    func sendReaction(_ emoji: CustomEmojiSendable, to targetMessageId: String) async throws {
        guard let scope = scopeProvider() else { throw CancellationError() }
        guard !targetMessageId.isEmpty else { throw CustomEmojiSendError.emptyEventTarget }
        let uploaded = try await upload([emoji], scope: scope)
        guard let reference = uploaded.first?.reference else { throw CustomEmojiSendError.uploadFailed }
        let tags = [try CustomEmojiTags.emojiTag(emoji.shortcode, reference: reference)]
        try CustomEmojiTags.validate(tags)
        try ensure(scope)
        do {
            try await sendReactionOperation(scope, targetMessageId, emoji.token, [reference], tags)
        } catch {
            throw classify(error, references: [reference])
        }
    }

    private func upload(_ emoji: [CustomEmojiSendable], scope: CustomEmojiScope) async throws -> [CustomEmojiUploadCache.Uploaded] {
        var uploaded: [CustomEmojiUploadCache.Uploaded] = []
        for item in emoji {
            uploaded.append(try await uploads.reference(for: item, scope: scope, currentEpoch: currentEpoch()))
            try ensure(scope)
        }
        return uploaded
    }

    private func ensure(_ scope: CustomEmojiScope) throws {
        guard scopeProvider() == scope, !Task.isCancelled else { throw CancellationError() }
    }

    /// A reference encrypted under an earlier epoch, or another branch at the
    /// same epoch, can never be sent: forget it so the retry re-encrypts once
    /// for the current one. While the epoch is unsettled the reference may
    /// still be good, so it is kept. Any other failure keeps it too.
    private func classify(_ error: Error, references: [MediaAttachmentReferenceFfi]) -> Error {
        if error is CancellationError || error is CustomEmojiSendError { return error }
        switch error as? MarmotKitError {
        case .MediaReferenceStaleEpoch?, .InvalidMediaReference?:
            references.forEach(uploads.invalidate)
            return CustomEmojiSendError.staleEpoch
        case .MediaReferenceEpochUnsettled?:
            return CustomEmojiSendError.epochUnsettled
        default:
            return CustomEmojiSendError.sendFailed
        }
    }
}

/// Runs one custom emoji composer send. The chat is claimed in the draft
/// store (which outlives the conversation screen) for the whole send, so no
/// composer for that chat, including one reopened mid-upload, can send the
/// same text again: `sendTaggedMedia` has no client token that could collapse
/// a duplicate. On acceptance the store clears the saved draft and records the
/// accepted submission before releasing the claim; the composer on screen
/// reconciles itself from that record. Optional cache writes come last.
@Observable
@MainActor
final class CustomEmojiComposerSubmitter {
    typealias Send = @MainActor (_ text: String, _ replyTargetId: String?,
                                 _ emoji: [CustomEmojiSendable]) async throws -> [CustomEmojiUploadCache.Uploaded]
    typealias Claim = @MainActor (CustomEmojiSubmittedDraft) -> UUID?
    typealias Finish = @MainActor (_ claim: UUID, _ submission: CustomEmojiSubmittedDraft, _ accepted: Bool) async -> Void
    typealias StoreSentBytes = @MainActor (_ uploaded: [CustomEmojiUploadCache.Uploaded], _ cacheGeneration: Int) async -> Void

    /// This screen's last outcome, for its inline error. Whether the chat has
    /// a send in flight is the draft store's claim, not this state.
    private(set) var state: CustomEmojiComposerSendState = .idle

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let claim: Claim
    @ObservationIgnored private let finish: Finish
    @ObservationIgnored private let storeSentBytes: StoreSentBytes
    @ObservationIgnored private let cacheGeneration: @MainActor () -> Int

    init(
        send: @escaping Send,
        claim: @escaping Claim,
        finish: @escaping Finish,
        storeSentBytes: @escaping StoreSentBytes,
        cacheGeneration: @escaping @MainActor () -> Int
    ) {
        self.send = send
        self.claim = claim
        self.finish = finish
        self.storeSentBytes = storeSentBytes
        self.cacheGeneration = cacheGeneration
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Returns true once MDK accepted the message. Refused (false, nothing
    /// sent) while the chat already has a send in flight.
    @discardableResult
    func submit(_ submission: CustomEmojiSubmittedDraft, emoji: [CustomEmojiSendable]) async -> Bool {
        guard let claimID = claim(submission) else { return false }
        state = .sending
        let generation = cacheGeneration()
        let uploaded: [CustomEmojiUploadCache.Uploaded]
        do {
            uploaded = try await send(submission.text, submission.replyTargetId, emoji)
        } catch is CancellationError {
            await finish(claimID, submission, false)
            state = .idle
            return false
        } catch {
            await finish(claimID, submission, false)
            state = .failed((error as? CustomEmojiSendError ?? .sendFailed).message)
            Haptics.error()
            return false
        }
        await finish(claimID, submission, true)
        state = .idle
        Haptics.tap()
        await storeSentBytes(uploaded, generation)
        return true
    }

    func report(_ error: CustomEmojiSendError) {
        guard state != .sending else { return }
        state = .failed(error.message)
        Haptics.error()
    }

    func dismissError() {
        guard state != .sending else { return }
        state = .idle
    }
}

/// Whether the composer on screen still shows an accepted custom emoji
/// submission and may clear itself. Anything the person changed while it
/// uploaded (text, reply target, an edit session, attachments) keeps it.
nonisolated enum CustomEmojiComposerReconciliation {
    static func clears(
        submitted: ConversationDraftSnapshot,
        canonicalText: String,
        replyTargetId: String?,
        hasMediaDrafts: Bool,
        isEditing: Bool
    ) -> Bool {
        guard !isEditing, !hasMediaDrafts else { return false }
        return ConversationDraftStore.isSameSubmission(
            ConversationDraftSnapshot(canonicalText: canonicalText, replyToMessageIdHex: replyTargetId, mediaAttachments: []),
            submitted
        )
    }
}

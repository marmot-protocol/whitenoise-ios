import Foundation
import MarmotKit
import Observation

/// Sends custom emoji messages for one conversation. Custom emoji reactions
/// are deferred: MDK 0.12.0 pins only `Media` sends to the attachments'
/// epoch, not `Reaction`, so a media reaction can be encrypted under a later
/// epoch than its image (#1137, marmot-protocol/mdk#2151).
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

    let uploads: CustomEmojiUploadCache
    private let scopeProvider: @MainActor () -> CustomEmojiScope?
    private let currentEpoch: @MainActor () -> UInt64?
    private let sendMessageOperation: SendMessage

    init(
        scopeProvider: @escaping @MainActor () -> CustomEmojiScope?,
        currentEpoch: @escaping @MainActor () -> UInt64?,
        loadBytes: @escaping CustomEmojiUploadCache.LoadBytes,
        upload: @escaping CustomEmojiUploadCache.Upload,
        sendMessage: @escaping SendMessage
    ) {
        self.scopeProvider = scopeProvider
        self.currentEpoch = currentEpoch
        self.sendMessageOperation = sendMessage
        self.uploads = CustomEmojiUploadCache(scopeProvider: scopeProvider, loadBytes: loadBytes, upload: upload)
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
        let references = uploaded.map(\.reference)
        do {
            try await sendMessageOperation(scope, text, references, tags)
        } catch {
            throw classify(error, references: references)
        }
        return uploaded
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

    /// MDK refuses a reference encrypted under an earlier epoch as an invalid
    /// media reference; forget it so the retry re-encrypts once for the new
    /// epoch. Any other failure keeps the uploaded reference for the retry.
    private func classify(_ error: Error, references: [MediaAttachmentReferenceFfi]) -> Error {
        if error is CancellationError || error is CustomEmojiSendError { return error }
        if case .InvalidMediaReference? = error as? MarmotKitError {
            references.forEach(uploads.invalidate)
            return CustomEmojiSendError.staleEpoch
        }
        return CustomEmojiSendError.sendFailed
    }
}

/// Runs one custom emoji composer send and hands its outcome back to the
/// composer. The send stays in flight (Send disabled, no new attachments)
/// until the saved draft is cleared and the composer has been told to clear
/// itself, because `sendTaggedMedia` has no client token that could collapse
/// a duplicate. Saved-draft cleanup runs here, not in the view, so it
/// completes even if the conversation closed during the upload.
@Observable
@MainActor
final class CustomEmojiComposerSubmitter {
    typealias Send = @MainActor (_ text: String, _ replyTargetId: String?,
                                 _ emoji: [CustomEmojiSendable]) async throws -> [CustomEmojiUploadCache.Uploaded]
    typealias CompleteDraft = @MainActor (CustomEmojiSubmittedDraft) async -> Void
    typealias StoreSentBytes = @MainActor (_ uploaded: [CustomEmojiUploadCache.Uploaded], _ cacheGeneration: Int) async -> Void

    private(set) var state: CustomEmojiComposerSendState = .idle

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let completeDraft: CompleteDraft
    @ObservationIgnored private let storeSentBytes: StoreSentBytes
    @ObservationIgnored private let cacheGeneration: @MainActor () -> Int

    init(
        send: @escaping Send,
        completeDraft: @escaping CompleteDraft,
        storeSentBytes: @escaping StoreSentBytes,
        cacheGeneration: @escaping @MainActor () -> Int
    ) {
        self.send = send
        self.completeDraft = completeDraft
        self.storeSentBytes = storeSentBytes
        self.cacheGeneration = cacheGeneration
    }

    var isSending: Bool { state == .sending }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Returns true once MDK accepted the message. A second call while one is
    /// in flight is refused. `onAccepted` clears the composer (if it is still
    /// on screen) before Send is enabled again; optional local cache writes
    /// happen only after that hand-off.
    @discardableResult
    func submit(
        _ submission: CustomEmojiSubmittedDraft,
        emoji: [CustomEmojiSendable],
        onAccepted: @MainActor () -> Void
    ) async -> Bool {
        guard state != .sending else { return false }
        state = .sending
        let generation = cacheGeneration()
        let uploaded: [CustomEmojiUploadCache.Uploaded]
        do {
            uploaded = try await send(submission.text, submission.replyTargetId, emoji)
        } catch is CancellationError {
            state = .idle
            return false
        } catch {
            state = .failed((error as? CustomEmojiSendError ?? .sendFailed).message)
            Haptics.error()
            return false
        }
        await completeDraft(submission)
        onAccepted()
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

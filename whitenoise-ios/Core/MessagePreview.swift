import Foundation
import MarmotKit

/// Shared rules for turning a message record into a one-line chat-list preview.
///
/// The conversation screen filters control events and renders structured
/// payloads; the chats list must do the same so it never shows a bare
/// reaction/delete (or a kind-1200 stream-start signal) as the preview.
enum MessagePreview {
    // Reply-preview media JSON is peer-controlled. Keep the raw byte budget
    // small because JSONSerialization materializes the whole blob before the
    // tag/field scan budgets apply.
    nonisolated static let timelineMediaPreviewMaxJsonBytes = 64 * 1024
    // Match the app's normal outgoing attachment ceiling so legitimate media
    // messages keep accurate reply-preview counts while hostile extras clip.
    static let timelineMediaPreviewMaxTags = MediaDraftProcessor.maxAttachmentCount + 2
    static let timelineMediaPreviewMaxFieldsPerTag = 16
    static let timelineMediaPreviewMaxFileNames = MediaDraftProcessor.maxAttachmentCount

    /// Whether a record should drive the chat-list preview. Skips agent-stream
    /// start signals and non-textual events (reactions, deletes). A kind-9
    /// stream-final is a real message and previews like any other chat.
    static func isPreviewable(_ record: AppMessageRecordFfi) -> Bool {
        switch MessageSemantics.classify(record) {
        case .reaction, .delete, .edit, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unknown:
            return false
        case .chat, .reply, .media, .streamFinal:
            return true
        }
    }

    /// The display text for a previewable record: reply text, a media caption /
    /// filename, or the plaintext for a plain message.
    static func body(
        _ record: AppMessageRecordFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil,
        systemEventNaming: GroupSystemEventNaming = .shortIdentities
    ) -> String {
        switch MessageSemantics.classify(record) {
        case .media(let attachments):
            if !record.plaintext.isEmpty {
                // A GIF sharing its message with photos classifies as media,
                // and its plaintext is the envelope, not a caption.
                if let giphy = giphyPreview(record.plaintext, mentionDisplayName: mentionDisplayName) {
                    return giphy
                }
                return flattenedBody(
                    plaintext: record.plaintext,
                    tokens: record.contentTokens,
                    mentionDisplayName: mentionDisplayName
                )
            }
            return mediaFallback(attachments)
        case .agentActivity, .agentOperation:
            return AgentEventPresentation.previewText(from: record.plaintext) ?? ""
        case .groupSystem:
            return GroupSystemEventPresentation.displayText(
                from: record.plaintext,
                sender: record.sender,
                currentAccountIdHex: systemEventNaming.currentAccountIdHex,
                displayName: systemEventNaming.displayName
            ) ?? ""
        case .chat, .reply, .streamFinal:
            // Reply text, stream transcript, and plain chat all live in plaintext.
            if let giphy = giphyPreview(record.plaintext, mentionDisplayName: mentionDisplayName) {
                return giphy
            }
            return flattenedBody(
                plaintext: record.plaintext,
                tokens: record.contentTokens,
                mentionDisplayName: mentionDisplayName
            )
        case .reaction, .delete, .edit, .agentStreamStart, .unknown:
            // Not previewable/displayable text: a reaction's emoji, a delete
            // tombstone, or a kind-1200 stream-start signal must never surface
            // as message body. Mirrors `isPreviewable(_:)` so the
            // previewable/displayable classification has a single source of
            // truth and never renders a bare reaction/stream-start as a preview.
            return ""
        }
    }

    static func body(
        _ preview: TimelineReplyPreviewFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil,
        systemEventNaming: GroupSystemEventNaming = .shortIdentities
    ) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            if preview.kind == MessageSemantics.kindGroupSystem {
                return GroupSystemEventPresentation.displayText(
                    from: preview.plaintext,
                    sender: preview.sender,
                    currentAccountIdHex: systemEventNaming.currentAccountIdHex,
                    displayName: systemEventNaming.displayName
                ) ?? ""
            }
            if MessageSemantics.isTypedAgentEventKind(preview.kind) {
                return AgentEventPresentation.previewText(from: preview.plaintext) ?? ""
            }
            if let giphy = giphyPreview(preview.plaintext, mentionDisplayName: mentionDisplayName) {
                return giphy
            }
            return flattenedBody(
                plaintext: preview.plaintext,
                tokens: preview.contentTokens,
                mentionDisplayName: mentionDisplayName
            )
        }
        if let mediaJson = preview.mediaJson {
            return mediaFallback(timelineMediaFileNames(from: mediaJson))
        }
        return preview.plaintext
    }

    static func body(
        _ preview: ChatListMessagePreviewFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil,
        systemEventNaming: GroupSystemEventNaming = .shortIdentities
    ) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            if preview.kind == MessageSemantics.kindGroupSystem {
                return GroupSystemEventPresentation.displayText(
                    from: preview.plaintext,
                    sender: preview.sender,
                    currentAccountIdHex: systemEventNaming.currentAccountIdHex,
                    displayName: systemEventNaming.displayName
                ) ?? ""
            }
            if MessageSemantics.isTypedAgentEventKind(preview.kind) {
                return AgentEventPresentation.previewText(from: preview.plaintext) ?? ""
            }
            if let giphy = giphyPreview(preview.plaintext, mentionDisplayName: mentionDisplayName) {
                return giphy
            }
            return flattenedBody(
                plaintext: preview.plaintext,
                tokens: preview.contentTokens,
                mentionDisplayName: mentionDisplayName
            )
        }
        return L10n.string("New message")
    }

    /// A GIF preview shows the sender's caption when there is one, and the
    /// generic label otherwise. The envelope's URL never becomes preview text.
    static func giphyPreview(
        _ plaintext: String,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String? {
        // The shared gate is looser than `parse`, so an envelope with a
        // clipped credit line still degrades to the label instead of leaking
        // the CDN URL; projection is a no-op on that label.
        guard let label = RemoteGiphyMedia.envelopePreviewText(for: plaintext) else { return nil }
        return CanonicalMentionDisplayProjection.project(label) { npub in
            mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
        }.text
    }

    /// Previews show markdown stripped of syntax when parsed tokens exist.
    /// Tokenless records preserve plaintext except for known canonical mentions,
    /// which still render with the profile name used by normal chat messages.
    private static func flattenedBody(
        plaintext: String,
        tokens: MarkdownDocumentFfi,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> String {
        guard !tokens.blocks.isEmpty else {
            return CanonicalMentionDisplayProjection.project(plaintext) { npub in
                mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
            }.text
        }
        return MarkdownPlainText.flatten(tokens, mentionDisplayName: mentionDisplayName) ?? plaintext
    }

    static func mediaFallback(_ attachments: [MediaAttachmentReferenceFfi]) -> String {
        mediaFallback(attachments.map(\.fileName))
    }

    private static func mediaFallback(_ fileNames: [String]) -> String {
        let names = fileNames
            .compactMap {
                ContentSanitizer.compactSingleLine(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines),
                    maxLength: MessageSemantics.maxImetaFileNameBytes
                )
            }
        if names.count == 1 {
            return "📎 \(names[0])"
        }
        if names.count > 1 {
            return L10n.plural("📎 %lld attachments", Int64(names.count))
        }
        return "📎 \(L10n.string("Attachment"))"
    }

    private static func timelineMediaFileNames(from mediaJson: String) -> [String] {
        guard mediaJson.utf8.count <= timelineMediaPreviewMaxJsonBytes,
              let data = mediaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imeta = root["imeta"] as? [[String]]
        else { return [] }
        var fileNames: [String] = []
        for tag in imeta.prefix(timelineMediaPreviewMaxTags) {
            for field in tag.dropFirst().prefix(timelineMediaPreviewMaxFieldsPerTag) where field.hasPrefix("filename ") {
                let name = String(field.dropFirst("filename ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    fileNames.append(name)
                    if fileNames.count == timelineMediaPreviewMaxFileNames {
                        return fileNames
                    }
                    break
                }
            }
        }
        return fileNames
    }
}

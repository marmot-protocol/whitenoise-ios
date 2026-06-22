import Foundation
import MarmotKit

/// Shared rules for turning a message record into a one-line chat-list preview.
///
/// The conversation screen filters control events and renders structured
/// payloads; the chats list must do the same so it never shows a bare
/// reaction/delete (or a kind-1200 stream-start signal) as the preview.
enum MessagePreview {
    /// Whether a record should drive the chat-list preview. Skips agent-stream
    /// start signals and non-textual events (reactions, deletes). A kind-9
    /// stream-final is a real message and previews like any other chat.
    static func isPreviewable(_ record: AppMessageRecordFfi) -> Bool {
        switch MessageSemantics.classify(record) {
        case .reaction, .delete, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unknown:
            return false
        case .chat, .reply, .media, .streamFinal:
            return true
        }
    }

    /// The display text for a previewable record: reply text, a media caption /
    /// filename, or the plaintext for a plain message.
    static func body(
        _ record: AppMessageRecordFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        switch MessageSemantics.classify(record) {
        case .media(let attachments):
            if !record.plaintext.isEmpty {
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
            return GroupSystemEventPresentation.displayText(from: record.plaintext) ?? ""
        case .chat, .reply, .streamFinal:
            // Reply text, stream transcript, and plain chat all live in plaintext.
            return flattenedBody(
                plaintext: record.plaintext,
                tokens: record.contentTokens,
                mentionDisplayName: mentionDisplayName
            )
        case .reaction, .delete, .agentStreamStart, .unknown:
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
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            if preview.kind == MessageSemantics.kindGroupSystem {
                return GroupSystemEventPresentation.displayText(from: preview.plaintext) ?? ""
            }
            if MessageSemantics.isTypedAgentEventKind(preview.kind) {
                return AgentEventPresentation.previewText(from: preview.plaintext) ?? ""
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
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            if preview.kind == MessageSemantics.kindGroupSystem {
                return GroupSystemEventPresentation.displayText(from: preview.plaintext) ?? ""
            }
            if MessageSemantics.isTypedAgentEventKind(preview.kind) {
                return AgentEventPresentation.previewText(from: preview.plaintext) ?? ""
            }
            return flattenedBody(
                plaintext: preview.plaintext,
                tokens: preview.contentTokens,
                mentionDisplayName: mentionDisplayName
            )
        }
        return L10n.string("New message")
    }

    /// Previews show markdown stripped of syntax when parsed tokens exist.
    /// Records without tokens (non-chat kinds, pre-markdown history) keep
    /// returning the exact plaintext so existing fallbacks are unchanged.
    private static func flattenedBody(
        plaintext: String,
        tokens: MarkdownDocumentFfi,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> String {
        guard !tokens.blocks.isEmpty else { return plaintext }
        return MarkdownPlainText.flatten(tokens, mentionDisplayName: mentionDisplayName) ?? plaintext
    }

    static func mediaFallback(_ attachments: [MediaAttachmentReferenceFfi]) -> String {
        mediaFallback(attachments.map(\.fileName))
    }

    private static func mediaFallback(_ fileNames: [String]) -> String {
        let names = fileNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if names.count == 1 {
            return "📎 \(names[0])"
        }
        if names.count > 1 {
            return L10n.plural("📎 %lld attachments", Int64(names.count))
        }
        return "📎 \(L10n.string("Attachment"))"
    }

    private static func timelineMediaFileNames(from mediaJson: String) -> [String] {
        guard let data = mediaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imeta = root["imeta"] as? [[String]]
        else { return [] }
        var fileNames: [String] = []
        for tag in imeta {
            for field in tag.dropFirst() where field.hasPrefix("filename ") {
                let name = String(field.dropFirst("filename ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    fileNames.append(name)
                    break
                }
            }
        }
        return fileNames
    }
}

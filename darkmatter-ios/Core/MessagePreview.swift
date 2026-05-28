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
        case .reaction, .delete, .agentStreamStart, .unknown:
            return false
        case .chat, .reply, .media, .streamFinal:
            return true
        }
    }

    /// The display text for a previewable record: reply text, a media caption /
    /// filename, or the plaintext for a plain message.
    static func body(_ record: AppMessageRecordFfi) -> String {
        switch MessageSemantics.classify(record) {
        case .media(let info):
            if !record.plaintext.isEmpty { return record.plaintext }
            return "📎 \(info.fileName)"
        case .chat, .reply, .streamFinal, .reaction, .delete, .agentStreamStart, .unknown:
            // Reply text, stream transcript, and plain chat all live in plaintext.
            return record.plaintext
        }
    }

    static func body(_ preview: TimelineReplyPreviewFfi) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            return preview.plaintext
        }
        if let mediaJson = preview.mediaJson {
            return "📎 \(timelineMediaFileName(from: mediaJson) ?? L10n.string("Attachment"))"
        }
        return preview.plaintext
    }

    static func body(_ preview: ChatListMessagePreviewFfi) -> String {
        if preview.deleted {
            return L10n.string("This message was deleted")
        }
        if !preview.plaintext.isEmpty {
            return preview.plaintext
        }
        return L10n.string("New message")
    }

    private static func timelineMediaFileName(from mediaJson: String) -> String? {
        guard let data = mediaJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imeta = root["imeta"] as? [[String]]
        else { return nil }
        for tag in imeta {
            for field in tag.dropFirst() where field.hasPrefix("filename ") {
                let name = String(field.dropFirst("filename ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
}

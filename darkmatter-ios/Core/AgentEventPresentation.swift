import Foundation
import MarmotKit

/// Display projection for durable agent timeline rows (kind 1201 / 1202).
///
/// UniFFI only parses markdown for kind 9, so these kinds arrive with empty
/// `content_tokens` and JSON in `plaintext`. Tags carry operation metadata.
nonisolated enum AgentEventPresentation {

    enum RowKind: Equatable {
        case activity
        case operation
    }

    struct Display: Equatable {
        var kind: RowKind
        var primaryText: String
        var secondaryText: String?
        var iconName: String
    }

    static func display(for record: AppMessageRecordFfi) -> Display? {
        switch MessageSemantics.classify(record) {
        case .agentActivity:
            return activityDisplay(record)
        case .agentOperation:
            return operationDisplay(record)
        default:
            return nil
        }
    }

    /// Shared JSON `text` / `preview` extraction for chat-list previews.
    static func previewText(from plaintext: String) -> String? {
        guard let payload = parsePayload(plaintext) else { return nil }
        return payload.resolvedPrimaryText
    }

    private static func activityDisplay(_ record: AppMessageRecordFfi) -> Display? {
        let payload = parsePayload(record.plaintext)
        let status = normalized(
            payload?.status
                ?? MessageSemantics.firstValue(of: "status", in: record.tags)
        )
        guard let primary = payload?.resolvedPrimaryText else { return nil }
        return Display(
            kind: .activity,
            primaryText: primary,
            secondaryText: activitySecondaryText(status: status),
            iconName: activityIcon(status: status)
        )
    }

    private static func operationDisplay(_ record: AppMessageRecordFfi) -> Display? {
        let payload = parsePayload(record.plaintext)
        let eventType = normalized(
            payload?.eventType
                ?? MessageSemantics.firstValue(of: "operation", in: record.tags)
        )
        let operationName = normalized(
            payload?.name
                ?? MessageSemantics.firstValue(of: "operation-name", in: record.tags)
        )
        guard let primary = payload?.resolvedPrimaryText else { return nil }
        return Display(
            kind: .operation,
            primaryText: primary,
            secondaryText: operationSecondaryText(name: operationName, eventType: eventType),
            iconName: operationIcon(eventType: eventType)
        )
    }

    private static func parsePayload(_ plaintext: String) -> Payload? {
        guard let data = plaintext.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Payload(
            text: root["text"] as? String,
            preview: root["preview"] as? String,
            status: root["status"] as? String,
            eventType: root["event_type"] as? String,
            name: root["name"] as? String
        )
    }

    private struct Payload {
        var text: String?
        var preview: String?
        var status: String?
        var eventType: String?
        var name: String?

        var resolvedPrimaryText: String? {
            if let text = trimmed(text) { return text }
            if let preview = trimmed(preview) { return preview }
            return nil
        }

        private func trimmed(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func activityIcon(status: String?) -> String {
        switch status {
        case "thinking":
            return "ellipsis.message"
        case "running", "started", "in_progress":
            return "sparkle"
        default:
            return "text.line.first.and.arrowtriangle.forward"
        }
    }

    private static func activitySecondaryText(status: String?) -> String? {
        guard let status else { return nil }
        switch status {
        case "thinking":
            return L10n.string("Thinking")
        default:
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func operationIcon(eventType: String?) -> String {
        switch eventType {
        case "tool_call":
            return "wrench.and.screwdriver"
        case "approval":
            return "hand.raised"
        case "hook":
            return "link"
        case "handoff":
            return "arrow.triangle.branch"
        case "delivery":
            return "paperplane"
        default:
            return "gearshape.2"
        }
    }

    private static func operationSecondaryText(name: String?, eventType: String?) -> String? {
        if let name {
            return name.replacingOccurrences(of: "_", with: " ")
        }
        guard let eventType else { return nil }
        return eventType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

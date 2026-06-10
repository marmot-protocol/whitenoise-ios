import SwiftUI
import MarmotKit

/// Visual grouping for streaming-debug timeline rows.
enum MessageDebugCategory: Hashable {
    case userVisible
    case streamSignaling
    case agentChrome
    case groupSystem
    case control
    case unknown

    var label: String {
        switch self {
        case .userVisible: "User-visible"
        case .streamSignaling: "Stream signal"
        case .agentChrome: "Agent chrome"
        case .groupSystem: "Group system"
        case .control: "Control"
        case .unknown: "Unknown"
        }
    }

    var accentColor: Color {
        switch self {
        case .userVisible: .green
        case .streamSignaling: .orange
        case .agentChrome: .purple
        case .groupSystem: .gray
        case .control: .yellow
        case .unknown: .red
        }
    }
}

/// Debug chrome applied to message bubbles when streaming debug is enabled.
struct MessageDebugStyle: Hashable {
    let category: MessageDebugCategory
    let kindLabel: String
    let tagsSummary: String
    let detailText: String

    var isUserVisibleBubble: Bool {
        category == .userVisible
    }
}

extension MessageSemantics {

    static func isUserVisibleBubble(_ kind: Kind) -> Bool {
        switch kind {
        case .chat, .reply, .media, .streamFinal:
            return true
        case .reaction, .delete, .agentStreamStart, .agentActivity, .agentOperation, .groupSystem, .unknown:
            return false
        }
    }

    static func debugStyle(for record: AppMessageRecordFfi) -> MessageDebugStyle {
        let semantics = classify(record)
        return MessageDebugStyle(
            category: debugCategory(for: semantics),
            kindLabel: debugKindLabel(for: semantics, recordKind: record.kind),
            tagsSummary: debugTagsSummary(record.tags),
            detailText: debugDetailText(for: record, semantics: semantics)
        )
    }

    private static func debugCategory(for kind: Kind) -> MessageDebugCategory {
        switch kind {
        case .chat, .reply, .media, .streamFinal:
            return .userVisible
        case .agentStreamStart:
            return .streamSignaling
        case .agentActivity, .agentOperation:
            return .agentChrome
        case .groupSystem:
            return .groupSystem
        case .reaction, .delete:
            return .control
        case .unknown:
            return .unknown
        }
    }

    private static func debugKindLabel(for kind: Kind, recordKind: UInt64) -> String {
        let name: String
        switch kind {
        case .chat: name = "chat"
        case .reply: name = "reply"
        case .media: name = "media"
        case .streamFinal: name = "stream-final"
        case .reaction: name = "reaction"
        case .delete: name = "delete"
        case .agentStreamStart: name = "agent-stream-start"
        case .agentActivity: name = "agent-activity"
        case .agentOperation: name = "agent-operation"
        case .groupSystem: name = "group-system"
        case .unknown: name = "unknown"
        }
        return "kind \(recordKind) · \(name)"
    }

    private static func debugTagsSummary(_ tags: [MessageTagFfi]) -> String {
        guard !tags.isEmpty else { return "tags: (none)" }
        let lines = tags.map { tag in
            tag.values.joined(separator: " ")
        }
        return "tags:\n" + lines.joined(separator: "\n")
    }

    private static func debugDetailText(for record: AppMessageRecordFfi, semantics: Kind) -> String {
        switch semantics {
        case .agentStreamStart(let start):
            var lines = [
                "stream: \(start.streamId)",
                "route: \(start.route)",
            ]
            if start.brokers.isEmpty {
                lines.append("brokers: (none)")
            } else {
                lines.append(contentsOf: start.brokers.map { "broker: \($0)" })
            }
            return lines.joined(separator: "\n")
        case .reaction(let target):
            return "target: \(target)\nemoji: \(record.plaintext.isEmpty ? "(un-react)" : record.plaintext)"
        case .delete(let target):
            return "target: \(target)"
        case .reply(let target):
            return "reply-to: \(target)\n\(formattedPlaintext(record.plaintext))"
        case .streamFinal(let streamId):
            return "stream: \(streamId)\n\(formattedPlaintext(record.plaintext))"
        case .media:
            if !record.plaintext.isEmpty {
                return "caption: \(record.plaintext)"
            }
            return "media attachment(s)"
        case .agentActivity, .agentOperation, .groupSystem:
            return formattedPlaintext(record.plaintext)
        case .chat:
            return formattedPlaintext(record.plaintext)
        case .unknown:
            return formattedPlaintext(record.plaintext)
        }
    }

    private static func formattedPlaintext(_ plaintext: String) -> String {
        guard let data = plaintext.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let formatted = String(data: pretty, encoding: .utf8)
        else {
            return plaintext.isEmpty ? "(empty)" : plaintext
        }
        return formatted
    }
}

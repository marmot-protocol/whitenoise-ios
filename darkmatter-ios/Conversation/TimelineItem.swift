import Foundation
import MarmotKit

/// Delivery state for a message bubble. Inbound messages are `.received`
/// (no indicator shown); our own messages move .sending → .sent, or .failed.
enum MessageStatus: Hashable {
    case received
    case sending
    case sent
    case failed
}

/// One renderable row in a conversation. Either a message bubble or a
/// system-style event (member joined/left, profile changed, etc.).
struct TimelineItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case message(record: AppMessageRecordFfi, status: MessageStatus)
        case systemEvent(SystemEvent)
    }

    let id: String
    let kind: Kind
    let timestamp: UInt64
}

/// System-rendered timeline events. We don't carry a full enum from the FFI
/// for v1 — the only state-change event marmot-app exposes per-group is
/// "the group record updated", so we project that into a small set of
/// presentational variants the view can render.
enum SystemEvent: Hashable {
    case groupCreated
    case groupRenamed(String)
    case groupArchived
    case groupUnarchived
    case rosterChanged
}

extension TimelineItem {
    static func message(_ record: AppMessageRecordFfi, status: MessageStatus? = nil) -> TimelineItem {
        let resolved = status ?? (record.direction == "sent" ? .sent : .received)
        return TimelineItem(
            id: "msg:\(record.messageIdHex.isEmpty ? UUID().uuidString : record.messageIdHex)",
            kind: .message(record: record, status: resolved),
            timestamp: record.recordedAt
        )
    }

    /// Optimistic (not-yet-confirmed) outgoing message keyed by a stable temp id.
    static func pendingMessage(tempId: String, record: AppMessageRecordFfi) -> TimelineItem {
        TimelineItem(
            id: "msg:\(tempId)",
            kind: .message(record: record, status: .sending),
            timestamp: record.recordedAt
        )
    }

    static func systemEvent(
        id: String,
        event: SystemEvent,
        timestamp: UInt64
    ) -> TimelineItem {
        TimelineItem(
            id: "evt:\(id)",
            kind: .systemEvent(event),
            timestamp: timestamp
        )
    }
}

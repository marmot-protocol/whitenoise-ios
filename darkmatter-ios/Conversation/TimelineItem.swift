import Foundation
import MarmotKit

/// Delivery state for a message bubble. Inbound messages are `.received`
/// (no indicator shown); our own messages move .sending → .sent, or .failed.
/// `.streaming` is a live agent-text-stream bubble still filling in.
enum MessageStatus: Hashable {
    case received
    case sending
    case sent
    case failed
    case streaming
}

/// One renderable row in a conversation. Either a message bubble or a
/// system-style event (member joined/left, profile changed, etc.).
struct TimelineItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case message(record: AppMessageRecordFfi, status: MessageStatus)
        case systemEvent(SystemEvent)
        case streamDebugEvent(StreamDebugTimelineEvent)
    }

    let id: String
    let kind: Kind
    let timestamp: UInt64
}

/// A live QUIC agent-stream update surfaced in streaming-debug mode.
struct StreamDebugTimelineEvent: Hashable {
    let streamId: String
    let eventKind: String
    let detail: String
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
    /// Sort key for a message row. Clamped to the earlier of the message's
    /// claimed send time and our local receive time, so a peer (or a skewed
    /// clock) can't set a far-future `recordedAt` to pin a message at the bottom
    /// of every conversation (#61). The bubble still *displays* the record's own
    /// `recordedAt`, so legitimate timestamps render unchanged.
    static func sortTimestamp(for record: AppMessageRecordFfi) -> UInt64 {
        record.receivedAt > 0 ? min(record.recordedAt, record.receivedAt) : record.recordedAt
    }

    static func message(_ record: AppMessageRecordFfi, status: MessageStatus? = nil) -> TimelineItem {
        let resolved = status ?? (record.direction == "sent" ? .sent : .received)
        return TimelineItem(
            id: "msg:\(record.messageIdHex.isEmpty ? UUID().uuidString : record.messageIdHex)",
            kind: .message(record: record, status: resolved),
            timestamp: sortTimestamp(for: record)
        )
    }

    /// Optimistic (not-yet-confirmed) outgoing message keyed by a stable temp id.
    static func pendingMessage(tempId: String, record: AppMessageRecordFfi) -> TimelineItem {
        TimelineItem(
            id: "msg:\(tempId)",
            kind: .message(record: record, status: .sending),
            timestamp: sortTimestamp(for: record)
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

    static func streamDebugEvent(
        id: String,
        streamId: String,
        eventKind: String,
        detail: String,
        timestamp: UInt64
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            kind: .streamDebugEvent(StreamDebugTimelineEvent(
                streamId: streamId,
                eventKind: eventKind,
                detail: detail
            )),
            timestamp: timestamp
        )
    }
}

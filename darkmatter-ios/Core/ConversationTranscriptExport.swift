import Foundation
import MarmotKit

protocol ConversationTranscriptTimelineReading {
    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi
}

extension Marmot: ConversationTranscriptTimelineReading {}

/// Builds a chronological JSON dump of inner Marmot/Nostr app events for debugging.
enum ConversationTranscriptExport {
    static let pageLimit: UInt32 = 200
    private static let protectedAttributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.complete
    ]

    struct Document: Encodable {
        var v: Int = 1
        var exportedAt: String
        var groupIdHex: String
        var groupName: String
        var eventCount: Int
        var events: [Event]

        enum CodingKeys: String, CodingKey {
            case v
            case exportedAt = "exported_at"
            case groupIdHex = "group_id_hex"
            case groupName = "group_name"
            case eventCount = "event_count"
            case events
        }
    }

    struct Event: Encodable {
        var index: Int
        var messageIdHex: String
        var sourceMessageIdHex: String?
        var kind: UInt64
        var content: String
        var tags: [[String]]
        var direction: String
        var sender: String
        var timelineAt: UInt64
        var receivedAt: UInt64
        var replyToMessageIdHex: String?
        var mediaJson: String?
        var agentTextStreamJson: String?
        var deleted: Bool
        var deletedByMessageIdHex: String?
        var invalidationStatus: String?

        enum CodingKeys: String, CodingKey {
            case index
            case messageIdHex = "message_id_hex"
            case sourceMessageIdHex = "source_message_id_hex"
            case kind
            case content
            case tags
            case direction
            case sender
            case timelineAt = "timeline_at"
            case receivedAt = "received_at"
            case replyToMessageIdHex = "reply_to_message_id_hex"
            case mediaJson = "media_json"
            case agentTextStreamJson = "agent_text_stream_json"
            case deleted
            case deletedByMessageIdHex = "deleted_by_message_id_hex"
            case invalidationStatus = "invalidation_status"
        }
    }

    static func fetchAllMessages(
        marmot: Marmot,
        accountRef: String,
        groupIdHex: String
    ) throws -> [TimelineMessageRecordFfi] {
        try fetchAllMessages(
            timelineReader: marmot,
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    static func fetchAllMessages(
        timelineReader: ConversationTranscriptTimelineReading,
        accountRef: String,
        groupIdHex: String
    ) throws -> [TimelineMessageRecordFfi] {
        var collected: [TimelineMessageRecordFfi] = []
        var before: UInt64?
        var beforeMessageId: String?

        while true {
            try Task.checkCancellation()
            let page = try timelineReader.timelineMessages(
                accountRef: accountRef,
                query: TimelineMessageQueryFfi(
                    groupIdHex: groupIdHex,
                    search: nil,
                    before: before,
                    beforeMessageId: beforeMessageId,
                    after: nil,
                    afterMessageId: nil,
                    limit: pageLimit
                )
            )
            try Task.checkCancellation()
            collected.append(contentsOf: page.messages)
            guard page.hasMoreBefore, let oldest = page.messages.last else { break }
            before = oldest.timelineAt
            beforeMessageId = oldest.messageIdHex
        }

        return sortChronologically(collected)
    }

    static func makeDocument(
        group: AppGroupRecordFfi,
        messages: [TimelineMessageRecordFfi],
        exportedAt: Date = Date()
    ) -> Document {
        let ordered = sortChronologically(messages)
        let events = ordered.enumerated().map { index, record in
            Event(
                index: index,
                messageIdHex: record.messageIdHex,
                sourceMessageIdHex: record.sourceMessageIdHex,
                kind: record.kind,
                content: record.plaintext,
                tags: record.tags.map(\.values),
                direction: record.direction,
                sender: record.sender,
                timelineAt: record.timelineAt,
                receivedAt: record.receivedAt,
                replyToMessageIdHex: record.replyToMessageIdHex,
                mediaJson: record.mediaJson,
                agentTextStreamJson: record.agentTextStreamJson,
                deleted: record.deleted,
                deletedByMessageIdHex: record.deletedByMessageIdHex,
                invalidationStatus: record.invalidationStatus
            )
        }
        return Document(
            exportedAt: iso8601Timestamp(exportedAt),
            groupIdHex: group.groupIdHex,
            groupName: group.name,
            eventCount: events.count,
            events: events
        )
    }

    static func encodeJSON(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func writeTemporaryFile(data: Data, groupIdHex: String, exportedAt: Date = Date()) throws -> URL {
        let prefix = String(groupIdHex.prefix(8))
        let stamp = iso8601Timestamp(exportedAt)
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkmatter-transcript-\(prefix)-\(stamp).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes(protectedAttributes, ofItemAtPath: url.path)
        return url
    }

    private static func sortChronologically(_ messages: [TimelineMessageRecordFfi]) -> [TimelineMessageRecordFfi] {
        messages.sorted { lhs, rhs in
            if lhs.timelineAt == rhs.timelineAt {
                return lhs.messageIdHex < rhs.messageIdHex
            }
            return lhs.timelineAt < rhs.timelineAt
        }
    }

    private static func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

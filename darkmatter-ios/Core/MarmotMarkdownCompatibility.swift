import Foundation
import MarmotKit

extension MarkdownDocumentFfi {
    static var emptyDocument: MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: [])
    }
}

extension AppMessageRecordFfi {
    init(
        messageIdHex: String,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64,
        receivedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }
}

extension ReceivedMessageFfi {
    init(
        messageIdHex: String,
        groupIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            groupIdHex: groupIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            recordedAt: recordedAt
        )
    }
}

extension ChatListMessagePreviewFfi {
    init(
        messageIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        kind: UInt64,
        timelineAt: UInt64,
        deleted: Bool
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted
        )
    }
}

extension TimelineMessageRecordFfi {
    init(
        messageIdHex: String,
        sourceMessageIdHex: String?,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        timelineAt: UInt64,
        receivedAt: UInt64,
        replyToMessageIdHex: String?,
        replyPreview: TimelineReplyPreviewFfi?,
        mediaJson: String?,
        agentTextStreamJson: String?,
        groupSystem: GroupSystemEventFfi? = nil,
        reactions: TimelineReactionSummaryFfi,
        deleted: Bool,
        deletedByMessageIdHex: String?,
        invalidationStatus: String?
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            timelineAt: timelineAt,
            receivedAt: receivedAt,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: mediaJson,
            agentTextStreamJson: agentTextStreamJson,
            groupSystem: groupSystem,
            reactions: reactions,
            deleted: deleted,
            deletedByMessageIdHex: deletedByMessageIdHex,
            invalidationStatus: invalidationStatus
        )
    }
}

extension TimelineReplyPreviewFfi {
    init(
        messageIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        mediaJson: String?,
        agentTextStreamJson: String?,
        deleted: Bool
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            mediaJson: mediaJson,
            agentTextStreamJson: agentTextStreamJson,
            deleted: deleted
        )
    }
}

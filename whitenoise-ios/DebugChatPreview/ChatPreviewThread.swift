#if DEBUG
import Foundation
import MarmotKit

nonisolated struct ChatPreviewThread {
    static let owner = String(repeating: "11", count: 32)
    static let peer = String(repeating: "22", count: 32)
    static let third = String(repeating: "33", count: 32)
    static let trailBot = String(repeating: "44", count: 32)
    static let members = [(owner, "You"), (peer, "Maya"), (third, "Leo")]
    static let catalogTime = Int(Date().timeIntervalSince1970)
    private(set) var firstUnreadIndex: Int?
    private var nextMessageNumber = 1
    private let people: [(String, String)]
    private let currentMemberIDs: [String]
    private var hasLeft: Bool { !currentMemberIDs.contains(Self.owner) }

    var incomingSampleSender: String? {
        guard !hasLeft else { return nil }
        return currentMemberIDs.first { $0 != Self.owner }
    }

    let number: Int
    let id: String
    let title: String
    let disappearingMessageSecs: UInt64
    let isDirect: Bool
    private(set) var messages: [ConversationMessageFfi] = []

    init(_ number: Int, _ title: String, direct: Bool = false, firstUnread: Int? = nil, openingDaysAgo: [Int] = [],
         people: [(String, String)]? = nil, formerMembers: Set<String> = [], disappearingMessageSecs: UInt64 = 0, _ lines: [PreviewLine]) {
        let groupID = String(format: "%064x", number)
        self.number = number
        id = groupID
        self.title = title
        self.isDirect = direct
        self.disappearingMessageSecs = disappearingMessageSecs
        self.people = people ?? Array(Self.members.prefix(direct ? 2 : 3))
        let memberIDs = direct ? [Self.owner, Self.peer] : self.people.map(\.0)
        currentMemberIDs = memberIDs.filter { !formerMembers.contains($0) }
        firstUnreadIndex = firstUnread
        let interval = firstUnread == nil ? 40 : 1_800
        let now = Self.catalogTime
        for (index, line) in lines.enumerated() {
            let time: Int
            if let date = line.date {
                time = Int(date.timeIntervalSince1970)
            } else if openingDaysAgo.indices.contains(index) {
                time = now - number - openingDaysAgo[index] * 86_400
            } else {
                time = now - number - (lines.count - 1 - index) * interval
            }
            append(line, at: UInt64(time))
        }
    }

    mutating func append(_ line: PreviewLine, at time: UInt64) {
        let messageID = String(format: "%032x%032x", number, nextMessageNumber)
        nextMessageNumber += 1
        let sender = line.author
        let record = TimelineMessageRecordFfi(clientToken: nil, hasReports: false, poll: nil,
            messageIdHex: messageID, sourceMessageIdHex: messageID, sourceEpoch: 1,
            retentionSeconds: nil, retentionExpiresAt: nil, direction: sender == Self.owner ? "sent" : "received",
            groupIdHex: id, sender: sender, plaintext: line.text, contentTokens: .emptyDocument,
            kind: MessageSemantics.kindChat, tags: [], sticker: nil, timelineAt: time, receivedAt: time,
            replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil, media: [], agentTextStreamJson: nil,
            groupSystem: nil, reactions: .init(byEmoji: [], userReactions: []), edit: nil, deleted: false,
            deletionSource: .unknown, deletedByMessageIdHex: nil, invalidationStatus: nil,
            recipientConfirmed: false, importedFrom: nil, historyImportProvenance: nil)
        var message = ConversationMessageFfi(timeline: record, references: .init(messageIdHex: messageID,
            sender: sender, replyAuthor: nil, mentions: [], mentionsTruncated: false, replyMentions: [],
            replyMentionsTruncated: false, system: nil, reactions: .init(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)))
        line.apply(to: &message, history: messages, identities: people)
        messages.append(message)
    }

    mutating func update(_ messageID: String, _ apply: (inout ConversationMessageFfi) -> Void) {
        guard let index = messages.firstIndex(where: { $0.timeline.messageIdHex == messageID }) else { return }
        apply(&messages[index])
    }

    mutating func redactQuotes(of id: String) {
        for index in messages.indices where messages[index].timeline.replyPreview?.messageIdHex == id {
            messages[index].timeline.replyPreview?.plaintext = ""
            messages[index].timeline.replyPreview?.contentTokens = .emptyDocument
            messages[index].timeline.replyPreview?.media = []
            messages[index].timeline.replyPreview?.mediaJson = nil
            messages[index].timeline.replyPreview?.sticker = nil
            messages[index].timeline.replyPreview?.deleted = true
            messages[index].timeline.replyPreview?.deletionSource = .author
        }
    }

    mutating func hide(_ id: String) {
        redactQuotes(of: id)
        guard let index = messages.firstIndex(where: { $0.timeline.messageIdHex == id }) else { return }
        let cutoff = firstUnreadIndex
        messages.remove(at: index)
        if let cutoff {
            let start = cutoff - (index < cutoff ? 1 : 0)
            firstUnreadIndex = messages.indices.dropFirst(start).first { messages[$0].timeline.direction == "received" }
        }
    }

    private var firstUnreadID: String? { firstUnreadIndex.map { messages[$0].timeline.messageIdHex } }
    private var lastRead: TimelineMessageRecordFfi? {
        guard let firstUnreadIndex else { return messages.last?.timeline }
        return firstUnreadIndex > 0 ? messages[firstUnreadIndex - 1].timeline : nil
    }
    private var unreadCount: UInt64 { UInt64(firstUnreadIndex.map { messages[$0...].filter { $0.timeline.direction == "received" }.count } ?? 0) }

    private var presentation: ConversationPresentationFfi {
        .init(title: .literal(text: title), avatar: .placeholder(stableSeed: id, source: isDirect ? .peerFallback : .groupFallback),
              titleSource: isDirect ? .peerProfile : .group, avatarSource: isDirect ? .peerFallback : .groupFallback,
              peerId: isDirect ? Self.peer : nil, resolution: .lastKnown)
    }

    var row: PresentedChatRowFfi {
        let last = messages.last?.timeline
        let preview = last.map { message in
            let mediaKinds: [ChatListAttachmentKindFfi] = message.media.map { outcome in
                guard case let .accepted(_, ref) = outcome else { return .file }
                switch ref.mediaType.split(separator: "/").first {
                case "image": return .photo
                case "audio": return .audio
                case "video": return .video
                default: return .file
                }
            }
            return ChatListMessagePreviewFfi(groupSystem: message.groupSystem, messageIdHex: message.messageIdHex,
                sender: message.sender, senderDisplayName: people.first { $0.0 == message.sender }?.1,
                plaintext: message.plaintext, contentTokens: message.contentTokens, kind: message.kind,
                sticker: message.sticker, timelineAt: message.timelineAt, retentionSeconds: message.retentionSeconds, retentionExpiresAt: message.retentionExpiresAt,
                deleted: message.deleted, deletionSource: message.deletionSource, attachmentKind: Set(mediaKinds).count > 1 ? .mixed : mediaKinds.first, attachmentCount: UInt32(mediaKinds.count),
                deliveryState: message.sender == Self.owner ? (message.invalidationStatus != nil ? .failed : message.sourceMessageIdHex == nil ? .pending : .delivered) : .notApplicable)
        }
        let time = last?.timelineAt ?? UInt64(Self.catalogTime - number)
        let row = ChatListRowFfi(groupIdHex: id, pinned: false, pinnedPosition: nil, archived: false,
            pendingConfirmation: false, lifecycleState: .stable, disbanding: false, disbandRequest: nil,
            title: title, groupName: isDirect ? "" : title, avatarUrl: nil, avatar: nil, lastMessage: preview,
            unreadCount: unreadCount, hasUnread: unreadCount > 0, manuallyMarkedUnread: false, unreadMentionCount: 0,
            unreadMention: false, firstUnreadMessageIdHex: firstUnreadID, lastReadMessageIdHex: lastRead?.messageIdHex,
            lastReadTimelineAt: lastRead?.timelineAt, conversationCreatedAt: messages.first?.timeline.timelineAt ?? time,
            activitySortAt: time, updatedAt: time, selfMembership: hasLeft ? .left : .member, conversationKind: isDirect ? .direct : .group,
            muted: false, mutedUntilMs: nil, leaveRequestPending: false, leaveRequestedAtMs: nil, leaveBlocked: false)
        return .init(draftVersion: nil, preview: preview == nil ? .empty : .message,
            actions: .init(canMarkRead: false, canMarkUnread: false, canPin: false, canUnpin: false,
                          canMute: false, canUnmute: false, canArchive: false, canRestore: false,
                          canStartLeave: false, canDeleteLocal: false),
            row: row, presentation: presentation, avatarAsset: nil)
    }

    var snapshot: ConversationWindowSnapshotFfi {
        let identities = people.map { key, name in
            ConversationIdentityFfi(accountIdHex: key, displayName: name,
                avatar: .placeholder(stableSeed: key, source: .peerFallback), hasCachedProfile: true, avatarAsset: nil)
        }
        return .init(revision: .init(generation: id, sequence: 1),
            header: .init(selected: presentation, memberCount: UInt64(currentMemberIDs.count), archived: false, epoch: 1,
                lifecycle: .stable, disbanding: false, unrecoverable: false,
                capabilities: .init(participation: hasLeft ? .left : .active, isSelfAdmin: false, isLastAdmin: false, canSend: !hasLeft,
                    canInvite: false, canEditGroup: false, canLeave: false, requiresSelfDemoteBeforeLeave: false,
                    canCancelLeave: false, canEnableDisbanding: false, canDisband: false), avatarAsset: nil),
            messages: messages, identities: identities,
            readState: .init(initialized: true, lastReadMessageIdHex: lastRead?.messageIdHex,
                lastReadTimelineAt: lastRead?.timelineAt, manuallyMarkedUnread: false, unreadCount: unreadCount,
                unreadMentionCount: 0, firstUnreadMessageIdHex: firstUnreadID),
            // Inert handle used only inside this process. This app never constructs a runtime.
            draft: .init(revision: MessageDraftRevisionFfi(noPointer: .init()), draft: nil), pendingConfirmation: false,
            anchor: .init(kind: messages.isEmpty ? .empty : .latest, index: messages.indices.last.map(UInt32.init)),
            hasMoreBefore: false, hasMoreAfter: false)
    }
}
#endif

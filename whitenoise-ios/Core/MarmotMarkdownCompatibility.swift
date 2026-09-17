import Foundation
import MarmotKit

extension MarkdownDocumentFfi {
    init(blocks: [MarkdownBlockFfi], truncated: Bool) {
        self.init(
            blocks: blocks,
            truncated: truncated,
            blankLinesBefore: Data(repeating: 0, count: blocks.count)
        )
    }

    static var emptyDocument: MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: [], truncated: false)
    }
}

extension MarkdownListItemFfi {
    init(blocks: [MarkdownBlockFfi], checked: Bool?) {
        self.init(
            blocks: blocks,
            checked: checked,
            blankLinesBefore: Data(repeating: 0, count: blocks.count)
        )
    }
}

extension EncryptedMediaVersionFfi {
    nonisolated init?(wireValue: String) {
        switch wireValue {
        case "encrypted-media-v1":
            self = .v1
        case "encrypted-media-v2":
            self = .v2
        default:
            return nil
        }
    }

    nonisolated var wireValue: String {
        switch self {
        case .v1:
            return "encrypted-media-v1"
        case .v2:
            return "encrypted-media-v2"
        }
    }
}

extension AppGroupEncryptedMediaComponentFfi {
    init(
        componentId: UInt32,
        component: String,
        required: Bool,
        mediaFormat: String,
        allowedLocatorKinds: [String],
        defaultBlobEndpoints: [AppBlobEndpointFfi]
    ) {
        self.init(
            componentId: componentId,
            component: component,
            required: required,
            version: EncryptedMediaVersionFfi(wireValue: mediaFormat),
            mediaFormat: mediaFormat,
            allowedLocatorKinds: allowedLocatorKinds,
            defaultBlobEndpoints: defaultBlobEndpoints
        )
    }
}

extension AppGroupRecordFfi {
    init(
        groupIdHex: String,
        endpoint: String,
        name: String,
        description: String,
        admins: [String],
        relays: [String],
        nostrGroupIdHex: String,
        avatarUrl: String?,
        avatarDim: String?,
        avatarThumbhash: String?,
        imageHashHex: String? = nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi,
        disappearingMessageSecs: UInt64 = 0,
        archived: Bool,
        pendingConfirmation: Bool,
        unrecoverable: Bool = false,
        selfMembership: SelfMembershipFfi = .member,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil,
        disbanding: Bool = false,
        disbandRequest: DisbandRequestFfi? = nil,
        disbanded: Bool = false,
        welcomerAccountIdHex: String?,
        viaWelcomeMessageIdHex: String?
    ) {
        self.init(
            groupIdHex: groupIdHex,
            protocolProfile: .current,
            endpoint: endpoint,
            profilePresent: true,
            name: name,
            description: description,
            admins: admins,
            relays: relays,
            nostrGroupIdHex: nostrGroupIdHex,
            avatarUrl: avatarUrl,
            avatarDim: avatarDim,
            avatarThumbhash: avatarThumbhash,
            imageHashHex: imageHashHex,
            encryptedMedia: encryptedMedia,
            disappearingMessageSecs: disappearingMessageSecs,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            unrecoverable: unrecoverable,
            selfMembership: selfMembership,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs,
            disbanding: disbanding,
            disbandRequest: disbandRequest,
            disbanded: disbanded,
            welcomerAccountIdHex: welcomerAccountIdHex,
            viaWelcomeMessageIdHex: viaWelcomeMessageIdHex
        )
    }
}

extension NotificationUpdateFfi {
    init(
        notificationKey: String,
        conversationKey: String,
        trigger: NotificationTriggerFfi,
        accountRef: String,
        accountIdHex: String,
        groupIdHex: String,
        groupName: String?,
        isDm: Bool,
        isMention: Bool,
        messageIdHex: String?,
        sender: NotificationUserFfi,
        receiver: NotificationUserFfi,
        previewText: String?,
        reactionEmoji: String?,
        reactedToPreview: String?,
        timestampMs: Int64,
        isFromSelf: Bool
    ) {
        self.init(
            notificationKey: notificationKey,
            conversationKey: conversationKey,
            trigger: trigger,
            trafficClass: .standard,
            accountRef: accountRef,
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            groupName: groupName,
            isDm: isDm,
            isMention: isMention,
            messageIdHex: messageIdHex,
            sender: sender,
            receiver: receiver,
            previewText: previewText,
            reactionEmoji: reactionEmoji,
            reactedToPreview: reactedToPreview,
            timestampMs: timestampMs,
            isFromSelf: isFromSelf
        )
    }
}

extension GroupDetailsFfi {
    init(group: AppGroupRecordFfi, members: [GroupMemberDetailsFfi]) {
        self.init(
            group: group,
            members: members,
            mlsState: AppGroupMlsStateFfi(
                groupIdHex: group.groupIdHex,
                protocolProfile: group.protocolProfile,
                lifecycleState: group.disbanded ? .disbanded : .stable,
                epoch: 0,
                memberCount: UInt32(clamping: members.count),
                unrecoverable: group.unrecoverable,
                requiredAppComponents: [],
                disbandingEnabled: false,
                disbanding: group.disbanding,
                disbandingBlockers: [],
                disbandRequest: group.disbandRequest
            )
        )
    }
}

extension ChatListRowFfi {
    init(
        groupIdHex: String,
        pinned: Bool,
        pinnedPosition: UInt32?,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        manuallyMarkedUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        conversationCreatedAt: UInt64,
        activitySortAt: UInt64,
        updatedAt: UInt64,
        selfMembership: SelfMembershipFfi,
        conversationKind: ChatConversationKindFfi,
        muted: Bool,
        mutedUntilMs: Int64?,
        leaveRequestPending: Bool,
        leaveRequestedAtMs: UInt64?
    ) {
        self.init(
            groupIdHex: groupIdHex,
            pinned: pinned,
            pinnedPosition: pinnedPosition,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            lifecycleState: .stable,
            disbanding: false,
            disbandRequest: nil,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            manuallyMarkedUnread: manuallyMarkedUnread,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: conversationCreatedAt,
            activitySortAt: activitySortAt,
            updatedAt: updatedAt,
            selfMembership: selfMembership,
            conversationKind: conversationKind,
            muted: muted,
            mutedUntilMs: mutedUntilMs,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs
        )
    }

    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        conversationCreatedAt: UInt64,
        activitySortAt: UInt64,
        updatedAt: UInt64,
        selfMembership: SelfMembershipFfi,
        lifecycleState: GroupLifecycleStateFfi = .stable,
        disbanding: Bool = false,
        disbandRequest: DisbandRequestFfi? = nil,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil
    ) {
        self.init(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            lifecycleState: lifecycleState,
            disbanding: disbanding,
            disbandRequest: disbandRequest,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            manuallyMarkedUnread: false,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: conversationCreatedAt,
            activitySortAt: activitySortAt,
            updatedAt: updatedAt,
            selfMembership: selfMembership,
            conversationKind: .unknown,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs
        )
    }

    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        updatedAt: UInt64,
        lifecycleState: GroupLifecycleStateFfi = .stable,
        disbanding: Bool = false,
        disbandRequest: DisbandRequestFfi? = nil,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil
    ) {
        self.init(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            lifecycleState: lifecycleState,
            disbanding: disbanding,
            disbandRequest: disbandRequest,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            manuallyMarkedUnread: false,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: updatedAt,
            activitySortAt: updatedAt,
            updatedAt: updatedAt,
            selfMembership: .member,
            conversationKind: .unknown,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs
        )
    }

    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        updatedAt: UInt64,
        selfMembership: SelfMembershipFfi,
        lifecycleState: GroupLifecycleStateFfi = .stable,
        disbanding: Bool = false,
        disbandRequest: DisbandRequestFfi? = nil,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil
    ) {
        self.init(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            lifecycleState: lifecycleState,
            disbanding: disbanding,
            disbandRequest: disbandRequest,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            manuallyMarkedUnread: false,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: updatedAt,
            activitySortAt: updatedAt,
            updatedAt: updatedAt,
            selfMembership: selfMembership,
            conversationKind: .unknown,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs
        )
    }
}

extension GroupManagementStateFfi {
    init(
        myAccountIdHex: String,
        isSelfAdmin: Bool,
        isLastAdmin: Bool,
        canInvite: Bool,
        canLeave: Bool,
        requiresSelfDemoteBeforeLeave: Bool,
        leaveRequestPending: Bool = false,
        leaveRequestedAtMs: UInt64? = nil,
        memberActions: [GroupMemberActionStateFfi]
    ) {
        self.init(
            myAccountIdHex: myAccountIdHex,
            isSelfAdmin: isSelfAdmin,
            isLastAdmin: isLastAdmin,
            canInvite: canInvite,
            canLeave: canLeave,
            requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestedAtMs,
            lifecycleState: .stable,
            disbandingEnabled: false,
            disbanding: false,
            canEnableDisbanding: false,
            canDisband: false,
            disbandingBlockers: [],
            disbandRequest: nil,
            memberActions: memberActions
        )
    }
}

extension AccountSummaryFfi {
    init(
        label: String,
        accountIdHex: String,
        localSigning: Bool,
        signedOut: Bool,
        running: Bool
    ) {
        self.init(
            label: label,
            accountIdHex: accountIdHex,
            localSigning: localSigning,
            externalSigning: false,
            signedOut: signedOut,
            running: running
        )
    }
}

extension SendSummaryFfi {
    init(published: UInt32, messageIds: [String]) {
        self.init(
            published: published,
            messageIds: messageIds,
            acceptDisposition: .published,
            maintenanceDisposition: .ready
        )
    }
}

extension AppMessageRecordFfi {
    init(
        messageIdHex: String,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
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
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }

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
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
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
        contentTokens: MarkdownDocumentFfi,
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
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            sourceEpoch: 0,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: 0
        )
    }

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
            sourceEpoch: 0,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: 0
        )
    }
}

extension ChatListMessagePreviewFfi {
    init(
        groupSystem: GroupSystemEventFfi? = nil,
        messageIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        timelineAt: UInt64,
        deleted: Bool
    ) {
        self.init(
            groupSystem: groupSystem,
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted,
            attachmentKind: nil,
            attachmentCount: 0,
            deliveryState: .notApplicable
        )
    }

    init(
        groupSystem: GroupSystemEventFfi? = nil,
        messageIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        kind: UInt64,
        timelineAt: UInt64,
        deleted: Bool
    ) {
        self.init(
            groupSystem: groupSystem,
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted,
            attachmentKind: nil,
            attachmentCount: 0,
            deliveryState: .notApplicable
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
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        tags: [MessageTagFfi],
        timelineAt: UInt64,
        receivedAt: UInt64,
        replyToMessageIdHex: String?,
        replyPreview: TimelineReplyPreviewFfi?,
        mediaJson: String?,
        media: [MediaAttachmentReferenceFfi],
        agentTextStreamJson: String?,
        groupSystem: GroupSystemEventFfi?,
        reactions: TimelineReactionSummaryFfi,
        edit: TimelineEditSummaryFfi? = nil,
        hasReports: Bool = false,
        deleted: Bool,
        deletedByMessageIdHex: String?,
        invalidationStatus: String?
    ) {
        self.init(
            hasReports: hasReports,
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            timelineAt: timelineAt,
            receivedAt: receivedAt,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: mediaJson,
            media: media.enumerated().map { .accepted(attachmentIndex: UInt32(clamping: $0.offset), reference: $0.element) },
            agentTextStreamJson: agentTextStreamJson,
            groupSystem: groupSystem,
            reactions: reactions,
            edit: edit,
            deleted: deleted,
            deletedByMessageIdHex: deletedByMessageIdHex,
            invalidationStatus: invalidationStatus
        )
    }

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
        media: [MediaAttachmentReferenceFfi] = [],
        agentTextStreamJson: String?,
        groupSystem: GroupSystemEventFfi? = nil,
        reactions: TimelineReactionSummaryFfi,
        edit: TimelineEditSummaryFfi? = nil,
        hasReports: Bool = false,
        deleted: Bool,
        deletedByMessageIdHex: String?,
        invalidationStatus: String?
    ) {
        self.init(
            hasReports: hasReports,
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
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
            media: media.enumerated().map { .accepted(attachmentIndex: UInt32(clamping: $0.offset), reference: $0.element) },
            agentTextStreamJson: agentTextStreamJson,
            groupSystem: groupSystem,
            reactions: reactions,
            edit: edit,
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
        media: [MediaAttachmentReferenceFfi] = [],
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
            media: media.enumerated().map { .accepted(attachmentIndex: UInt32(clamping: $0.offset), reference: $0.element) },
            agentTextStreamJson: agentTextStreamJson,
            deleted: deleted,
            invalidationStatus: nil
        )
    }
}

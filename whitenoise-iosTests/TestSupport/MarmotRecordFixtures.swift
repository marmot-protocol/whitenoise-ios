import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

func unsignedEventRecord(
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi]
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("dd"),
        direction: "received",
        groupIdHex: hex("aa"),
        sender: hex("11"),
        plaintext: plaintext,
        kind: kind,
        tags: tags,
        recordedAt: 1,
        receivedAt: 1
    )
}

/// Spells a nil `sourceMessageIdHex` for `timelineRecord`, whose omitted
/// argument means "same as `messageIdHex`".
extension Optional where Wrapped == String? {
    static var absent: Self { .some(nil) }
}

func timelineRecord(
    messageIdHex: String,
    // Delivered by default, mirroring the engine (received rows always carry
    // a source id; own rows carry one once delivered). Pass `.absent` for a
    // row without one, such as a committed-but-undelivered own row.
    sourceMessageIdHex: String?? = nil,
    direction: String = "received",
    groupIdHex: String = hex("aa"),
    sender: String = hex("11"),
    plaintext: String = "hello",
    contentTokens: MarkdownDocumentFfi = .emptyDocument,
    kind: UInt64 = MessageSemantics.kindChat,
    tags: [MessageTagFfi] = [],
    timelineAt: UInt64,
    receivedAt: UInt64? = nil,
    replyToMessageIdHex: String? = nil,
    replyPreview: TimelineReplyPreviewFfi? = nil,
    mediaJson: String? = nil,
    media: [MediaAttachmentReferenceFfi] = [],
    agentTextStreamJson: String? = nil,
    groupSystem: GroupSystemEventFfi? = nil,
    reactions: TimelineReactionSummaryFfi = TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
    deleted: Bool = false,
    deletedByMessageIdHex: String? = nil,
    invalidationStatus: String? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: sourceMessageIdHex ?? messageIdHex,
        direction: direction,
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        contentTokens: contentTokens,
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: receivedAt ?? timelineAt,
        replyToMessageIdHex: replyToMessageIdHex,
        replyPreview: replyPreview,
        mediaJson: mediaJson,
        media: media,
        agentTextStreamJson: agentTextStreamJson,
        groupSystem: groupSystem,
        reactions: reactions,
        edit: nil,
        deleted: deleted,
        deletedByMessageIdHex: deletedByMessageIdHex,
        invalidationStatus: invalidationStatus
    )
}

func message(
    id: String,
    kind: UInt64 = MessageSemantics.kindChat,
    groupIdHex: String = hex("aa"),
    sender: String = hex("11"),
    plaintext: String = "hello",
    tags: [MessageTagFfi] = [],
    recordedAt: UInt64 = 1
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: id,
        direction: "received",
        groupIdHex: groupIdHex,
        sender: sender,
        plaintext: plaintext,
        kind: kind,
        tags: tags,
        recordedAt: recordedAt,
        receivedAt: recordedAt
    )
}

func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

let mebibyte: UInt64 = 1_048_576

func attachmentPolicy(
    automatic: Bool = true,
    retained: UInt64 = 512 * mebibyte,
    reserve: UInt64 = 256 * mebibyte,
    transfer: UInt64 = 64 * mebibyte
) -> AttachmentDownloadPolicyFfi {
    AttachmentDownloadPolicyFfi(automatic: automatic, retainedBytes: retained, diskReserve: reserve,
                                transferLimit: transfer)
}

func encryptedMediaReference(
    fileName: String = "a.jpg",
    plaintextByte: String = "33",
    ciphertextByte: String = "44",
    nonce: String = String(repeating: "22", count: 12),
    mediaType: String = "image/jpeg",
    dim: String? = "640x480",
    sourceEpoch: UInt64
) -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(
            kind: "blossom-v1",
            value: "https://media.example/\(hex(ciphertextByte)).bin"
        )],
        ciphertextSha256: hex(ciphertextByte),
        plaintextSha256: hex(plaintextByte),
        nonceHex: nonce,
        fileName: fileName,
        mediaType: mediaType,
        version: .v1,
        sourceEpoch: sourceEpoch,
        dim: dim,
        thumbhash: nil
    )
}

func encryptedMediaComponent(
    version: EncryptedMediaVersionFfi = .v2
) -> AppGroupEncryptedMediaComponentFfi {
    AppGroupEncryptedMediaComponentFfi(
        componentId: version == .v1 ? 0x8008 : 0x800b,
        component: version == .v1
            ? "marmot.group.encrypted-media.v1"
            : "marmot.group.encrypted-media.v2",
        required: true,
        version: version,
        mediaFormat: version.wireValue,
        allowedLocatorKinds: ["blossom-v1"],
        defaultBlobEndpoints: [
            AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
        ]
    )
}

func group(
    name: String,
    id: String = hex("aa"),
    admins: [String] = [],
    avatarUrl: String? = nil,
    archived: Bool = false,
    pendingConfirmation: Bool = false,
    unrecoverable: Bool = false,
    selfMembership: SelfMembershipFfi = .member,
    leaveRequestPending: Bool = false,
    disbanding: Bool = false,
    disbandRequest: DisbandRequestFfi? = nil,
    disbanded: Bool = false,
    welcomerAccountIdHex: String? = nil,
    encryptedMedia: AppGroupEncryptedMediaComponentFfi = encryptedMediaComponent()
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: id,
        endpoint: "",
        name: name,
        description: "",
        admins: admins,
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: avatarUrl,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: encryptedMedia,
        archived: archived,
        pendingConfirmation: pendingConfirmation,
        unrecoverable: unrecoverable,
        selfMembership: selfMembership,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil,
        disbanding: disbanding,
        disbandRequest: disbandRequest,
        disbanded: disbanded,
        welcomerAccountIdHex: welcomerAccountIdHex,
        viaWelcomeMessageIdHex: nil
    )
}

func groupMember(memberIdHex: String, isAdmin: Bool, isSelf: Bool) -> GroupMemberDetailsFfi {
    GroupMemberDetailsFfi(
        memberIdHex: memberIdHex,
        account: memberIdHex,
        local: isSelf,
        isAdmin: isAdmin,
        isSelf: isSelf,
        npub: "npub-\(IdentityFormatter.short(memberIdHex))",
        displayName: nil
    )
}

func notificationUpdate(
    notificationKey: String = "notif-a",
    conversationKey: String = "conv-a",
    trigger: NotificationTriggerFfi = .newMessage,
    accountRef: String = "account-a",
    accountIdHex: String = hex("11"),
    groupIdHex: String = "group-a",
    isDm: Bool = true,
    isMention: Bool = false,
    groupName: String? = nil,
    senderAccountIdHex: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    senderName: String? = "Alice",
    previewText: String? = "Hello",
    reactionEmoji: String? = nil,
    reactedToPreview: String? = nil,
    messageIdHex: String? = "message-a",
    isFromSelf: Bool = false,
    timestampMs: Int64 = 1_700_000_000_123
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: conversationKey,
        trigger: trigger,
        accountRef: accountRef,
        accountIdHex: accountIdHex,
        groupIdHex: groupIdHex,
        groupName: groupName,
        isDm: isDm,
        isMention: isMention,
        messageIdHex: messageIdHex,
        sender: NotificationUserFfi(
            accountIdHex: senderAccountIdHex,
            displayName: senderName,
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: accountIdHex,
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: reactionEmoji,
        reactedToPreview: reactedToPreview,
        timestampMs: timestampMs,
        isFromSelf: isFromSelf
    )
}

func managementState(
    isSelfAdmin: Bool,
    isLastAdmin: Bool,
    canLeave: Bool? = nil,
    requiresSelfDemoteBeforeLeave: Bool? = nil,
    leaveRequestPending: Bool = false,
    lifecycleState: GroupLifecycleStateFfi = .stable,
    disbandingEnabled: Bool = false,
    disbanding: Bool = false,
    canEnableDisbanding: Bool = false,
    canDisband: Bool = false,
    disbandingBlockers: [String] = [],
    disbandRequest: DisbandRequestFfi? = nil
) -> GroupManagementStateFfi {
    GroupManagementStateFfi(
        myAccountIdHex: hex("11"),
        isSelfAdmin: isSelfAdmin,
        isLastAdmin: isLastAdmin,
        canInvite: isSelfAdmin,
        canLeave: leaveRequestPending ? false : (canLeave ?? !isSelfAdmin),
        requiresSelfDemoteBeforeLeave: requiresSelfDemoteBeforeLeave ?? isSelfAdmin,
        leaveRequestPending: leaveRequestPending,
        leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil,
        lifecycleState: lifecycleState,
        disbandingEnabled: disbandingEnabled,
        disbanding: disbanding,
        canEnableDisbanding: canEnableDisbanding,
        canDisband: canDisband,
        disbandingBlockers: disbandingBlockers,
        disbandRequest: disbandRequest,
        memberActions: []
    )
}

/// A conversation-window snapshot shaped like the one MDK delivers for a
/// freshly created group, so `ConversationViewModel.installConversationWindow`
/// can be driven without a runtime. The draft revision is an inert fake: it
/// must never be handed back to MDK.
func conversationWindowSnapshot(
    groupIdHex: String = hex("aa"),
    title: String = "Group",
    epoch: UInt64 = 1,
    messages: [ConversationMessageFfi] = [],
    identities: [ConversationIdentityFfi] = []
) -> ConversationWindowSnapshotFfi {
    ConversationWindowSnapshotFfi(
        revision: ConversationWindowRevisionFfi(generation: "fixture", sequence: 1),
        header: ConversationHeaderFfi(
            selected: ConversationPresentationFfi(
                title: .literal(text: title),
                avatar: .placeholder(stableSeed: groupIdHex, source: .groupFallback),
                titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
            ),
            memberCount: 1, archived: false, epoch: epoch, lifecycle: .stable, disbanding: false,
            unrecoverable: false,
            capabilities: ConversationCapabilitiesFfi(
                participation: .active, isSelfAdmin: true, isLastAdmin: true, canSend: true, canInvite: true,
                canEditGroup: true, canLeave: false, requiresSelfDemoteBeforeLeave: true,
                canEnableDisbanding: false, canDisband: false
            ),
            avatarAsset: nil
        ),
        messages: messages,
        identities: identities,
        readState: ConversationOpenReadStateFfi(
            initialized: true, lastReadMessageIdHex: nil, lastReadTimelineAt: nil, manuallyMarkedUnread: false,
            unreadCount: 0, unreadMentionCount: 0, firstUnreadMessageIdHex: nil
        ),
        // Pointerless fake: never pass it to MDK or call includesChatListVersion on it.
        draft: SelectedMessageDraftFfi(revision: MessageDraftRevisionFfi(noPointer: .init()), draft: nil),
        pendingConfirmation: false,
        anchor: ConversationAnchorOutcomeFfi(kind: .empty, index: nil),
        hasMoreBefore: false,
        hasMoreAfter: false
    )
}

/// Wraps a timeline record in the bounded display references a window carries.
func conversationMessage(
    _ record: TimelineMessageRecordFfi,
    reactions: ConversationReactionsFfi = ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)
) -> ConversationMessageFfi {
    ConversationMessageFfi(timeline: record, references: ConversationMessageReferencesFfi(
        messageIdHex: record.messageIdHex, sender: record.sender, replyAuthor: nil, mentions: [],
        mentionsTruncated: false, replyMentions: [], replyMentionsTruncated: false, system: nil,
        reactions: reactions
    ))
}

func keyPackage(
    eventId: String = "event",
    publishedAt: UInt64 = 1,
    local: Bool,
    relay: Bool
) -> AccountKeyPackageFfi {
    AccountKeyPackageFfi(
        accountRef: nil,
        accountIdHex: "account",
        keyPackageId: "keyPackageId-\(eventId)",
        keyPackageRefHex: "keyPackageRef-\(eventId)",
        eventIdHex: eventId,
        publishedAt: publishedAt,
        keyPackageBytes: 32,
        sourceRelays: relay ? ["wss://relay.example"] : [],
        local: local,
        relay: relay
    )
}

func relayLists(
    defaultRelays: [String] = [],
    bootstrapRelays: [String],
    nip65: [String],
    inbox: [String]
) -> AccountRelayListsFfi {
    AccountRelayListsFfi(
        complete: true,
        missing: [],
        defaultRelays: defaultRelays,
        bootstrapRelays: bootstrapRelays,
        nip65: RelayListFfi(kind: 10_002, relays: nip65),
        inbox: RelayListFfi(kind: 10_050, relays: inbox)
    )
}

/// Relay lists that name the same relays for every role.
func relayLists(_ relays: [String]) -> AccountRelayListsFfi {
    relayLists(defaultRelays: relays, bootstrapRelays: relays, nip65: relays, inbox: relays)
}

func keyPackageRelayEvent(eventId: String, account: String = "account") -> AccountKeyPackageRelayEventFfi {
    AccountKeyPackageRelayEventFfi(
        accountIdHex: account, keyPackageId: "history", keyPackageRefHex: "history-ref", eventIdHex: eventId,
        createdAt: 1, keyPackageBytes: 32, sourceRelays: ["wss://relay.example"], isCurrent: false)
}

/// A maintenance status naming `record` as the current key package.
func maintenanceStatus(currentKeyPackage record: AccountKeyPackageFfi) -> KeyPackageMaintenanceStatusFfi {
    KeyPackageMaintenanceStatusFfi(
        stableSlotId: "slot", phase: .quiet, currentKeyPackageRefHex: record.keyPackageRefHex, currentNotBefore: nil,
        currentNotAfter: nil, authoredEventIdHex: record.eventIdHex, authoredEventCreatedAt: record.publishedAt,
        acceptedFanoutTargets: 0, unattemptedFanoutTargets: 0, failedFanoutTargets: 0,
        policyProhibitedFanoutTargets: 0, refreshAt: nil, lastConsumedKeyPackageRefHex: nil,
        retainedPrivateMaterialCount: 0, pendingEventIdHex: nil, pendingAttemptCount: 0,
        pendingLastFailureCode: nil)
}

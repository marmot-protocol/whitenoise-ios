import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
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

func timelineRecord(
    messageIdHex: String,
    // Delivered by default, mirroring the engine (received rows always carry
    // a source id; own rows carry one once delivered). Pass `.some(nil)` to
    // build a committed-but-undelivered own row.
    sourceMessageIdHex: String?? = nil,
    direction: String = "received",
    groupIdHex: String = hex("aa"),
    sender: String = hex("11"),
    plaintext: String = "hello",
    kind: UInt64 = MessageSemantics.kindChat,
    tags: [MessageTagFfi] = [],
    timelineAt: UInt64,
    receivedAt: UInt64? = nil,
    replyToMessageIdHex: String? = nil,
    replyPreview: TimelineReplyPreviewFfi? = nil,
    mediaJson: String? = nil,
    media: [MediaAttachmentReferenceFfi] = [],
    agentTextStreamJson: String? = nil,
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
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: receivedAt ?? timelineAt,
        replyToMessageIdHex: replyToMessageIdHex,
        replyPreview: replyPreview,
        mediaJson: mediaJson,
        media: media,
        agentTextStreamJson: agentTextStreamJson,
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
            accountIdHex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
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

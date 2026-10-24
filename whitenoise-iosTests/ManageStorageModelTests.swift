import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Presented chat-list updates reach chats this screen lists, so avatars that
/// finish acquiring and renamed chats show without leaving the screen.
@MainActor
struct ManageStorageModelTests {
    private static let readyAsset = AvatarAssetFfi(target: "avatar-target", reference: "avatar-ref",
                                                   availability: .ready, acquisition: nil,
                                                   contentRevision: 2, byteCount: 512)

    private static func model(chats: [String], attachmentChats: [String] = []) -> ManageStorageModel {
        ManageStorageModel.fixture(
            usage: AttachmentStorageUsageFfi(mediaBytes: 0, legacyBytes: 0, attachmentCount: 0, databaseBytes: 0,
                                             databaseFreeBytes: 0, migration: .notNeeded, migrationBytes: 0,
                                             cacheBytes: 0),
            chats: chats.map { (ChatAttachmentUsageFfi(groupIdHex: $0, bytes: 1, attachmentCount: 1), "Before") },
            attachments: attachmentChats.map {
                RetainedAttachmentSummaryFfi(
                    groupIdHex: $0,
                    target: AttachmentLocalTargetFfi(messageIdHex: "m-\($0)", sourceMessageIdHex: "m-\($0)",
                                                     attachmentIndex: 0),
                    byteCount: 1, mediaType: "image/jpeg", fileName: "", receivedAt: 1
                )
            }
        )
    }

    private static func presented(_ groupIdHex: String, title: String, asset: AvatarAssetFfi?,
                                  pending: Bool = false) -> PresentedChatRowFfi {
        let row = ChatListRowFfi(
            groupIdHex: groupIdHex, pinned: false, pinnedPosition: nil, archived: false,
            pendingConfirmation: pending, title: "", groupName: "", avatarUrl: nil, avatar: nil,
            lastMessage: nil, unreadCount: 0, hasUnread: false, manuallyMarkedUnread: false,
            unreadMentionCount: 0, unreadMention: false, firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil, lastReadTimelineAt: nil, conversationCreatedAt: 1,
            activitySortAt: 1, updatedAt: 1, selfMembership: .member, conversationKind: .group,
            muted: false, mutedUntilMs: nil, leaveRequestPending: false, leaveRequestedAtMs: nil
        )
        let presentation = ConversationPresentationFfi(
            title: .literal(text: title), avatar: .placeholder(stableSeed: "seed-\(groupIdHex)", source: .group),
            titleSource: .group, avatarSource: .group, peerId: nil, resolution: .lastKnown
        )
        return PresentedChatRowFfi(row: row, presentation: presentation, avatarAsset: asset)
    }

    @Test func updatesRefreshTitlesAndAvatarsOfListedChats() {
        let model = Self.model(chats: ["listed"])
        #expect(model.identity(for: "listed").avatarAsset == nil)

        model.applyPresentedRows([Self.presented("listed", title: "Renamed", asset: Self.readyAsset)],
                                 using: AppState.test())

        #expect(model.identity(for: "listed").title == "Renamed")
        #expect(model.identity(for: "listed").avatarAsset == Self.readyAsset)
    }

    @Test func chatsOnlyInAnAttachmentListAreRefreshedToo() {
        let model = Self.model(chats: [], attachmentChats: ["from-attachment"])
        model.applyPresentedRows([Self.presented("from-attachment", title: "Hiking", asset: nil)],
                                 using: AppState.test())
        #expect(model.identity(for: "from-attachment").title == "Hiking")
    }

    /// Rows for chats this screen does not list are ignored, so no avatar is
    /// requested for anything off screen.
    @Test func unlistedChatsAreIgnored() {
        let model = Self.model(chats: ["listed"])
        model.applyPresentedRows([Self.presented("elsewhere", title: "Elsewhere", asset: Self.readyAsset)],
                                 using: AppState.test())
        #expect(model.identity(for: "elsewhere").title == L10n.string("Conversation unavailable"))
        #expect(model.identity(for: "elsewhere").avatarAsset == nil)
    }

    @Test func pendingInvitationsKeepAvatarEgressSuppressed() {
        let model = Self.model(chats: ["invite"])
        model.applyPresentedRows([Self.presented("invite", title: "Invite", asset: Self.readyAsset, pending: true)],
                                 using: AppState.test())
        #expect(model.identity(for: "invite").title == "Invite")
        #expect(model.identity(for: "invite").avatarAsset == nil)
    }
}

/// Removals drop the host's decrypted copies of what MDK removed, and no more.
@MainActor
struct ManageStorageRemovalTests {
    /// Only bulk removals, which report a count, drop every profile's decrypted
    /// copies; a single Remove drops just its own file, and Clear Cache none.
    @Test func onlyBulkRemovalsDropEveryDecryptedCopy() {
        #expect(ManageStorageModel.Operation.removeOlder(.account).removesInBulk)
        #expect(ManageStorageModel.Operation.removeOlder(.chat("g")).removesInBulk)
        #expect(ManageStorageModel.Operation.removeChat("g").removesInBulk)
        #expect(!ManageStorageModel.Operation.removeAttachment("g:m:s:0").removesInBulk)
        #expect(!ManageStorageModel.Operation.clearCache.removesInBulk)
    }

    /// The removed file's decrypted copy is found by its original message, source and slot.
    @Test func singleRemovalNamesTheRemovedFilesPlaintext() {
        func reference(_ plaintext: Character) -> MediaAttachmentReferenceFfi {
            MediaAttachmentReferenceFfi(locators: [], ciphertextSha256: String(repeating: "a", count: 64),
                plaintextSha256: String(repeating: plaintext, count: 64), nonceHex: String(repeating: "c", count: 24),
                fileName: "photo.jpg", mediaType: "image/jpeg", version: .v1, sourceEpoch: 1, dim: nil, thumbhash: nil)
        }
        func entry(message: String, source: String, _ attachment: MediaAttachmentOutcomeFfi) -> AttachmentEntryFfi {
            AttachmentEntryFfi(messageIdHex: message, sourceMessageIdHex: source, sender: "sender", timelineAt: 1,
                               receivedAt: 1, sourceEpoch: nil, category: .image, role: .shared, attachment: attachment)
        }
        let target = AttachmentLocalTargetFfi(messageIdHex: "edit", sourceMessageIdHex: "original", attachmentIndex: 2)
        let rejected = MediaAttachmentRejectionFfi(kind: .unsupportedFormat, detail: "bad")
        let entries = [
            entry(message: "edit", source: "other", .accepted(attachmentIndex: 2, reference: reference("1"))),
            entry(message: "other", source: "original", .accepted(attachmentIndex: 2, reference: reference("2"))),
            entry(message: "edit", source: "original", .rejected(attachmentIndex: 2, rejection: rejected)),
            entry(message: "edit", source: "original", .accepted(attachmentIndex: 1, reference: reference("3"))),
            entry(message: "edit", source: "original", .accepted(attachmentIndex: 2, reference: reference("4"))),
        ]

        #expect(MarmotClient.plaintextHash(in: entries, for: target) == String(repeating: "4", count: 64))
        #expect(MarmotClient.plaintextHash(in: Array(entries.dropLast()), for: target) == nil)
    }
}

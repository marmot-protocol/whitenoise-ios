import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

// Existing projection fixtures use the same message and invite selection as MDK.
extension PresentedChatRowFfi {
    init(row: ChatListRowFfi, presentation: ConversationPresentationFfi, avatarAsset: AvatarAssetFfi?) {
        self.init(
            preview: row.lastMessage != nil ? .message : (row.pendingConfirmation ? .invitation : .empty),
            actions: Self.testActions(), row: row, presentation: presentation, avatarAsset: avatarAsset
        )
    }

    static func testActions(
        read: Bool = false, unread: Bool = false, pin: Bool = false, unpin: Bool = false,
        mute: Bool = false, unmute: Bool = false, archive: Bool = false, restore: Bool = false,
        leave: Bool = false, delete: Bool = false
    ) -> ChatListRowActionsFfi {
        ChatListRowActionsFfi(
            canMarkRead: read, canMarkUnread: unread, canPin: pin, canUnpin: unpin,
            canMute: mute, canUnmute: unmute, canArchive: archive, canRestore: restore,
            canStartLeave: leave, canDeleteLocal: delete
        )
    }
}

@MainActor
struct Marmot0103IntegrationTests {
    @Test func publishedBinarySelectsExactDraftPreviewAndActions() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start("0.10.3 prepared rows", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Prepared rows", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let original = try #require(try await client.presentedChatListRow(accountRef: account.label, groupIdHex: group.groupIdHex))
            let selection = try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex)
            let exactText = "  " + String(repeating: "x", count: 1100) + "  "
            let saved = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: selection.revision,
                snapshot: ConversationDraftSnapshot(canonicalText: exactText, replyToMessageIdHex: nil, mediaAttachments: []))
            let prepared = try #require(try await client.presentedChatListRow(accountRef: account.label, groupIdHex: group.groupIdHex))
            guard case .draft(let preview) = prepared.preview else {
                Issue.record("Published binary did not select the saved draft")
                try await client.marmot.shutdownAndClose()
                return
            }
            #expect(preview.text.count == 1024)
            #expect(preview.textTruncated)
            #expect(preview.attachmentCount == 0)
            #expect(saved.draft?.content == exactText)
            #expect(prepared.row.activitySortAt == original.row.activitySortAt)
            #expect(prepared.row.unreadCount == original.row.unreadCount)
            #expect(prepared.actions.canStartLeave)
            #expect(!prepared.actions.canDeleteLocal)
            _ = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: saved.revision,
                snapshot: ConversationDraftSnapshot(canonicalText: " \n ", replyToMessageIdHex: nil, mediaAttachments: []))
            let cleared = try #require(try await client.presentedChatListRow(accountRef: account.label, groupIdHex: group.groupIdHex))
            #expect(cleared.preview == original.preview)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func preparedDraftIsBoundedAndDoesNotExposeAttachmentNames() {
        let draft = ChatListDraftPreviewFfi(text: "  Hello\nworld  ", textTruncated: false, attachmentCount: 2, attachmentKind: .mixed)
        #expect(ConversationDraftPreview.preparedText(draft) == "Hello world")
        let photo = ChatListDraftPreviewFfi(text: "", textTruncated: false, attachmentCount: 1, attachmentKind: .photo)
        #expect(ConversationDraftPreview.preparedText(photo) == L10n.string("Photo"))
        let large = ChatListDraftPreviewFfi(text: String(repeating: "a", count: 1024), textTruncated: true, attachmentCount: 0, attachmentKind: nil)
        #expect(ConversationDraftPreview.preparedText(large).count <= ConversationDraftPreview.maximumLength + 1)
    }

    @Test func projectedActionsControlGestures() {
        let hints = PresentedChatRowFfi.testActions(unpin: true, mute: true, restore: true, delete: true)
        #expect(ChatListSwipeActionsPresentation.leadingActions(hints) == [.unpin])
        #expect(ChatListSwipeActionsPresentation.trailingActions(hints, isMuted: false) == [.unarchive, .mute, .delete])
        #expect(ChatListSwipeActionsPresentation.trailingActions(hints, isMuted: true) == [.unarchive, .unmute, .delete])
        let pending = PresentedChatRowFfi.testActions(archive: true)
        #expect(ChatListSwipeActionsPresentation.leadingActions(pending).isEmpty)
        #expect(ChatListSwipeActionsPresentation.trailingActions(pending, isMuted: false) == [.archive])
    }
}

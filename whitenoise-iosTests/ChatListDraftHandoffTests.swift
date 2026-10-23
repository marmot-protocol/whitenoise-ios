import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

/// Stands in for MDK's opaque revision so the presentation decision can be
/// exercised without a runtime; the published binary is covered below.
// Immutable after init and used only by these tests; it must subclass the
// UniFFI object, whose Sendable conformance is unchecked.
// swiftlint:disable:next no_unchecked_sendable
private final class FakeDraftRevision: MessageDraftRevisionFfi, @unchecked Sendable {
    private let includes: Bool

    init(includes: Bool) {
        self.includes = includes
        super.init(noPointer: MessageDraftRevisionFfi.NoPointer())
    }

    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("Fake revisions are never lifted from Rust")
    }

    override func includesChatListVersion(version: ChatListDraftVersionFfi) -> Bool { includes }
}

private func fakeVersion() -> ChatListDraftVersionFfi {
    ChatListDraftVersionFfi(noPointer: ChatListDraftVersionFfi.NoPointer())
}

private func draftPreview(_ text: String) -> SelectedChatPreviewFfi {
    .draft(draft: ChatListDraftPreviewFfi(text: text, textTruncated: false, attachmentCount: 0, attachmentKind: nil))
}

private func submittedSummary(_ content: String) -> MessageDraftSummaryFfi {
    MessageDraftSummaryFfi(groupIdHex: "handoff-chat", content: content, replyToMessageIdHex: nil,
                           mediaAttachments: [], createdAtMs: 1, updatedAtMs: 1)
}

private func handoffRow() -> ChatListRowFfi {
    ChatListRowFfi(
        groupIdHex: "handoff-chat", pinned: false, pinnedPosition: nil, archived: false,
        pendingConfirmation: false, title: "Chat", groupName: "Chat", avatarUrl: nil, avatar: nil,
        lastMessage: nil, unreadCount: 0, hasUnread: false, manuallyMarkedUnread: false,
        unreadMentionCount: 0, unreadMention: false, firstUnreadMessageIdHex: nil,
        lastReadMessageIdHex: nil, lastReadTimelineAt: nil, conversationCreatedAt: 1,
        activitySortAt: 1, updatedAt: 1, selfMembership: .member, conversationKind: .group,
        muted: false, mutedUntilMs: nil, leaveRequestPending: false, leaveRequestedAtMs: nil
    )
}

private func preparedRow(preview: SelectedChatPreviewFfi, draftVersion: ChatListDraftVersionFfi?) -> PresentedChatRowFfi {
    let row = handoffRow()
    return PresentedChatRowFfi(
        draftVersion: draftVersion, preview: preview, actions: PresentedChatRowFfi.testActions(), row: row,
        presentation: ConversationPresentationFfi(
            title: .literal(text: row.title),
            avatar: .placeholder(stableSeed: row.groupIdHex, source: .groupFallback),
            titleSource: .group, avatarSource: .groupFallback, peerId: nil, resolution: .lastKnown
        ),
        avatarAsset: nil
    )
}

private func item(_ prepared: PresentedChatRowFfi, pendingSend: PendingDraftSendHandoff?) -> ChatsListViewModel.Item {
    ChatsListViewModel.Item(row: prepared.row, avatarURL: nil, title: "Chat", prepared: prepared, pendingSend: pendingSend)
}

private func preview(_ item: ChatsListViewModel.Item) -> ChatRowPreviewPresentation {
    ChatRow.previewPresentation(for: item, activeAccountIdHex: nil, senderName: { _ in "Sender" })
}

struct ChatListDraftHandoffTests {
    @Test func onlyAnIncludedDraftVersionIsCovered() {
        let included = FakeDraftRevision(includes: true)
        let newer = FakeDraftRevision(includes: false)
        #expect(ChatListDraftHandoff.coversDraftPreview(draftPreview("hi"), draftVersion: fakeVersion(), sentRevision: included))
        // A newer edit (even identical text), recreated draft or other store/group.
        #expect(!ChatListDraftHandoff.coversDraftPreview(draftPreview("hi"), draftVersion: fakeVersion(), sentRevision: newer))
        // Missing metadata is not evidence that the row shows the sent draft.
        #expect(!ChatListDraftHandoff.coversDraftPreview(draftPreview("hi"), draftVersion: nil, sentRevision: included))
        #expect(!ChatListDraftHandoff.coversDraftPreview(draftPreview("hi"), draftVersion: fakeVersion(), sentRevision: nil))
        // Rows that no longer show a draft need no handoff.
        for selected in [SelectedChatPreviewFfi.message, .empty, .invitation] {
            #expect(!ChatListDraftHandoff.coversDraftPreview(selected, draftVersion: fakeVersion(), sentRevision: included))
        }
        #expect(!ChatListDraftHandoff.coversDraftPreview(nil, draftVersion: fakeVersion(), sentRevision: included))
    }

    @Test func handoffOutlivesOnlyAnAcceptedSendThatLeftNoDraft() {
        #expect(PendingDraftSendHandoff.retainsAfterSend(accepted: true, selectedHasDraft: false))
        #expect(!PendingDraftSendHandoff.retainsAfterSend(accepted: true, selectedHasDraft: true))
        #expect(!PendingDraftSendHandoff.retainsAfterSend(accepted: true, selectedHasDraft: nil))
        #expect(!PendingDraftSendHandoff.retainsAfterSend(accepted: false, selectedHasDraft: false))
        #expect(!PendingDraftSendHandoff.retainsAfterSend(accepted: false, selectedHasDraft: nil))
    }

    @Test func coveredDraftPresentsThePendingOutgoingMessage() {
        let handoff = PendingDraftSendHandoff(revision: FakeDraftRevision(includes: true),
                                              submitted: submittedSummary("  See you\nat noon "))
        let covered = item(preparedRow(preview: draftPreview("See you at noon"), draftVersion: fakeVersion()),
                           pendingSend: handoff)
        #expect(covered.draftPreview == nil)
        #expect(covered.pendingSendPreview == "See you at noon")
        #expect(covered.searchHaystack.contains("see you at noon"))
        #expect(preview(covered) == ChatRowPreviewPresentation(prefix: L10n.string("You"), body: "See you at noon"))
    }

    @Test func newerDraftStaysVisibleDuringAPendingSend() {
        let handoff = PendingDraftSendHandoff(revision: FakeDraftRevision(includes: false),
                                              submitted: submittedSummary("See you at noon"))
        let newer = item(preparedRow(preview: draftPreview("See you at noon"), draftVersion: fakeVersion()),
                         pendingSend: handoff)
        #expect(newer.pendingSendPreview == nil)
        #expect(newer.draftPreview == "See you at noon")
        #expect(preview(newer).body == L10n.formatted("Draft: %@", "See you at noon"))

        let unversioned = item(preparedRow(preview: draftPreview("Older"), draftVersion: nil),
                               pendingSend: PendingDraftSendHandoff(revision: FakeDraftRevision(includes: true),
                                                                    submitted: submittedSummary("Sent")))
        #expect(unversioned.pendingSendPreview == nil)
        #expect(unversioned.draftPreview == "Older")
    }

    @Test func pendingSendWithoutPreviewTextUsesGenericSentCopy() {
        let handoff = PendingDraftSendHandoff(revision: FakeDraftRevision(includes: true),
                                              submitted: submittedSummary("   "))
        let covered = item(preparedRow(preview: draftPreview(""), draftVersion: fakeVersion()), pendingSend: handoff)
        #expect(covered.pendingSendPreview == "")
        #expect(preview(covered) == ChatRowPreviewPresentation(prefix: nil, body: L10n.string("You sent a message")))
    }
}

@MainActor
@Suite(.serialized, .tags(.runtime), .marmotRuntimeConcurrencyLimit)
struct ChatListDraftHandoffBindingTests {
    @Test func publishedBinaryCorrelatesSendRevisionWithChatListDraftVersion() async throws {
        let client = try MarmotClient.testClient()
        let defaults = try #require(UserDefaults(suiteName: "DraftHandoffTests.\(UUID())"))
        let store = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let state = AppState.test(client: client, notifications: .shared, conversationDraftStore: store,
            accountDefaults: defaults, erasureDefaults: defaults)
        state.setPhase(.ready)
        let watchdog = MarmotFixtureWatchdog.start("Draft handoff did not complete", breaking: client)
        defer { watchdog.cancel() }
        func draft(_ text: String) -> ConversationDraftSnapshot {
            ConversationDraftSnapshot(canonicalText: text, replyToMessageIdHex: nil, mediaAttachments: [])
        }
        try await closing(client) {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            func group(_ name: String) async throws -> String {
                try await client.createGroupWithOptionsDetailed(accountRef: account.label, name: name, memberRefs: [],
                    options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0)).groupIdHex
            }
            func row(_ groupIdHex: String) async throws -> PresentedChatRowFfi {
                try #require(try await client.presentedChatListRow(accountRef: account.label, groupIdHex: groupIdHex))
            }

            // Rejected before acceptance: the row covered by the send shows its
            // draft again, and the draft was never deleted on that basis.
            let rejected = try await group("Rejected")
            let generation = store.pendingSendHandoffGeneration
            let revision = try await store.prepareSend(draft("see you soon"), accountRef: account.label, groupIdHex: rejected)
            #expect(store.pendingSendHandoffGeneration != generation)
            let handoff = try #require(store.pendingSendHandoff(accountRef: account.label, groupIdHex: rejected))
            let sent = try await row(rejected)
            #expect(ChatListDraftHandoff.coversDraftPreview(sent.preview, draftVersion: sent.draftVersion,
                                                            sentRevision: handoff.revision))
            let pending = ChatsListViewModel.Item(row: sent.row, avatarURL: nil, title: "Rejected",
                                                  prepared: sent, pendingSend: handoff)
            #expect(pending.draftPreview == nil)
            #expect(pending.pendingSendPreview == "see you soon")
            // Saving identical text is a newer edit and must stay visible.
            _ = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: revision,
                                                            snapshot: draft("see you soon"))
            let resaved = try await row(rejected)
            #expect(!ChatListDraftHandoff.coversDraftPreview(resaved.preview, draftVersion: resaved.draftVersion,
                                                             sentRevision: revision))
            #expect(ChatsListViewModel.Item(row: resaved.row, avatarURL: nil, title: "Rejected", prepared: resaved,
                                            pendingSend: handoff).draftPreview == "see you soon")
            await store.finishSend(accountRef: account.label, groupIdHex: rejected, accepted: false)
            #expect(store.pendingSendHandoff(accountRef: account.label, groupIdHex: rejected) == nil)
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: rejected)
                .draft?.content == "see you soon")

            // Accepted: MDK consumes exactly the sent revision; the handoff
            // stays for stale snapshots but never covers a later draft.
            let accepted = try await group("Accepted")
            let acceptedRevision = try await store.prepareSend(draft("on my way"), accountRef: account.label, groupIdHex: accepted)
            _ = try await client.sendDraftWithClientToken(accountRef: account.label, revision: acceptedRevision,
                                                          attachments: [], clientToken: UUID().uuidString)
            await store.finishSend(accountRef: account.label, groupIdHex: accepted, accepted: true)
            let retained = try #require(store.pendingSendHandoff(accountRef: account.label, groupIdHex: accepted))
            let consumed = try await row(accepted)
            #expect(consumed.preview != draftPreview("on my way"))
            #expect(!ChatListDraftHandoff.coversDraftPreview(consumed.preview, draftVersion: consumed.draftVersion,
                                                             sentRevision: retained.revision))
            store.setDraft(draft("next thought"), accountRef: account.label, groupIdHex: accepted)
            await store.flush()
            let next = try await row(accepted)
            #expect(!ChatListDraftHandoff.coversDraftPreview(next.preview, draftVersion: next.draftVersion,
                                                             sentRevision: retained.revision))
            #expect(ChatsListViewModel.Item(row: next.row, avatarURL: nil, title: "Accepted", prepared: next,
                                            pendingSend: retained).draftPreview == "next thought")
        }
    }
}

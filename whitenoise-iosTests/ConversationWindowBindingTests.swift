import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .marmotRuntimeConcurrencyLimit)
struct ConversationWindowBindingTests {
    @Test func draftStorePreservesTypingDuringSendAndRequiresConflictResolution() async throws {
        try await withTestClient { client in
            let defaults = try #require(UserDefaults(suiteName: "DraftWindowTests.\(UUID())"))
            let store = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let state = AppState.test(client: client, conversationDraftStore: store,
                accountDefaults: defaults, erasureDefaults: defaults)
            state.setPhase(.ready)
            let watchdog = MarmotFixtureWatchdog.start(
                "Draft store send did not complete", breaking: client)
            defer { watchdog.cancel() }
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Draft store", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0)).requireCreated()
            let key = ConversationDraftKey(accountRef: account.label, groupIdHex: group.groupIdHex)
            func draft(_ text: String) -> ConversationDraftSnapshot {
                ConversationDraftSnapshot(canonicalText: text, replyToMessageIdHex: nil, mediaAttachments: [])
            }
            let revision = try await store.prepareSend(draft("send me"), accountRef: account.label, groupIdHex: group.groupIdHex)
            store.setDraft(draft(""), accountRef: account.label, groupIdHex: group.groupIdHex)
            store.setDraft(draft("next message"), accountRef: account.label, groupIdHex: group.groupIdHex)
            await store.flush()
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "send me")
            // The composer's token-aware send; local admission doesn't wait on the relay.
            _ = try await client.sendDraftWithClientToken(accountRef: account.label, revision: revision,
                attachments: [], clientToken: UUID().uuidString)
            await store.finishSend(accountRef: account.label, groupIdHex: group.groupIdHex, accepted: true)
            await store.flush()
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "next message")

            let selected = try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex)
            let externalSelection = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: selected.revision, snapshot: draft("other editor"))
            store.receiveSelection(externalSelection, accountRef: account.label, groupIdHex: group.groupIdHex)
            store.setDraft(draft("my unsaved text"), accountRef: account.label, groupIdHex: group.groupIdHex)
            await store.flush()
            #expect(store.conflictedKeys.contains(key))
            #expect(await store.snapshot(accountRef: account.label, groupIdHex: group.groupIdHex)?.canonicalText == "my unsaved text")
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "other editor")
            try await store.resolveConflict(accountRef: account.label, groupIdHex: group.groupIdHex, keepLocal: true)
            await store.flush()
            #expect(!store.conflictedKeys.contains(key))
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "my unsaved text")
        }
    }

    /// A send waits its turn behind the one before it. The next message typed
    /// meanwhile must not be saved over the tapped one: that save would leave
    /// out its large attachment, MDK would delete the file, and the claim
    /// would send the caption alone. The next message is saved afterwards.
    @Test func typingWhileASendWaitsKeepsItsLargeAttachment() async throws {
        try await withLargeAttachmentDraft { client, store, ref, chat, video in
            let tapped = ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: [video])
            // Send tap, then the next message while the send waits its turn.
            store.beginQueuedSend(accountRef: ref, groupIdHex: chat)
            store.setDraft(ConversationDraftSnapshot(canonicalText: "", replyToMessageIdHex: nil, mediaAttachments: []),
                           accountRef: ref, groupIdHex: chat)
            store.setDraft(ConversationDraftSnapshot(canonicalText: "next message", replyToMessageIdHex: nil, mediaAttachments: []),
                           accountRef: ref, groupIdHex: chat)
            await store.flush()
            _ = try await store.prepareSend(tapped, accountRef: ref, groupIdHex: chat)

            let claimed = try #require(try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft)
            #expect(claimed.content == "caption")
            #expect(claimed.mediaAttachments.map(\.id) == [video.id.uuidString])
            await store.finishSend(accountRef: ref, groupIdHex: chat, accepted: false)
            await store.flush()
            #expect(try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft?.content == "next message")
        }
    }

    /// A reopened composer can be edited before its draft's files arrive.
    /// Until it receives them, no write drops them (MDK would delete the file),
    /// and no send claims a revision holding one the composer doesn't show.
    /// Once received, removing one removes it.
    @Test func editsBeforeHydrationKeepTheDraftsFiles() async throws {
        try await withLargeAttachmentDraft { client, store, ref, chat, video in
            func text(_ value: String) -> ConversationDraftSnapshot {
                ConversationDraftSnapshot(canonicalText: value, replyToMessageIdHex: nil, mediaAttachments: [])
            }
            func saved() async throws -> SelectedMessageDraftContentFfi? {
                try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft
            }
            _ = await store.loadSnapshot(accountRef: ref, groupIdHex: chat, hydratingComposer: true)

            store.setDraft(text("typed early"), accountRef: ref, groupIdHex: chat)
            await store.flush()
            let early = try await saved()
            #expect(early?.content == "typed early")
            #expect(early?.mediaAttachments.map(\.id) == [video.id.uuidString])

            store.setDraft(text(""), accountRef: ref, groupIdHex: chat)
            await store.flush()
            let cleared = try await saved()
            #expect(cleared?.mediaAttachments.map(\.id) == [video.id.uuidString])

            store.beginQueuedSend(accountRef: ref, groupIdHex: chat)
            await #expect(throws: MarmotKitError.self) {
                try await store.prepareSend(text("caption only"), accountRef: ref, groupIdHex: chat)
            }

            store.composerReceivedAttachments([video], accountRef: ref, groupIdHex: chat)
            store.setDraft(text("typed early"), accountRef: ref, groupIdHex: chat)
            await store.flush()
            let removed = try await saved()
            #expect(removed?.mediaAttachments.isEmpty == true)
        }
    }

    /// Suspending the runtime doesn't wait out a large copy into the draft:
    /// the copy is cancelled and the caption saved. The next edit copies the
    /// attachment again.
    @Test func suspendingCancelsADraftCopyAndSavesTheCaption() async throws {
        try await withLargeAttachmentDraft(staged: false) { client, store, ref, chat, video in
            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: [video]),
                           accountRef: ref, groupIdHex: chat)
            await store.flush(using: client)
            let draft = try #require(try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft)
            #expect(draft.content == "caption")
            #expect(!store.sendsThroughDraft([video], accountRef: ref, groupIdHex: chat))

            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption, edited", replyToMessageIdHex: nil, mediaAttachments: [video]),
                           accountRef: ref, groupIdHex: chat)
            try await eventually { store.sendsThroughDraft([video], accountRef: ref, groupIdHex: chat) }
        }
    }

    /// A runtime with one chat whose draft holds `video` (over the inline
    /// draft limit) as a file, unless `staged` is false.
    private func withLargeAttachmentDraft(
        staged: Bool = true,
        _ body: (MarmotClient, ConversationDraftStore, String, String, MediaDraftAttachment) async throws -> Void
    ) async throws {
        try await withTestClient { client in
            let defaults = try #require(UserDefaults(suiteName: "DraftClaimTests.\(UUID())"))
            let store = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let state = AppState.test(client: client, conversationDraftStore: store,
                accountDefaults: defaults, erasureDefaults: defaults)
            state.setPhase(.ready)
            let watchdog = MarmotFixtureWatchdog.start("Large attachment draft did not settle", breaking: client)
            defer { watchdog.cancel() }
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Large draft", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0)).requireCreated()
            let video = MediaDraftAttachment(fileName: "clip.mov", mediaType: "video/quicktime",
                data: Data(count: MediaDraftProcessor.maxDraftAttachmentBytes + 1), dim: nil)
            if staged {
                store.setDraft(ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: [video]),
                               accountRef: account.label, groupIdHex: group.groupIdHex)
                try await eventually { store.sendsThroughDraft([video], accountRef: account.label, groupIdHex: group.groupIdHex) }
                await store.flush()
            }
            try await body(client, store, account.label, group.groupIdHex, video)
        }
    }

    @Test(arguments: [false, true])
    func draftSendStatusDistinguishesAcceptedFromRejectedAdmission(accepted: Bool) async throws {
        try await withTestClient { client in
            let defaults = try #require(UserDefaults(suiteName: "DraftSendFailureTests.\(UUID())"))
            let drafts = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let state = AppState.test(client: client, conversationDraftStore: drafts,
                accountDefaults: defaults, erasureDefaults: defaults)
            state.setPhase(.ready)
            let watchdog = MarmotFixtureWatchdog.start("Draft send recovery did not complete", breaking: client)
            defer { watchdog.cancel() }
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Send recovery", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0)).requireCreated()
            state.activeAccountRef = account.label
            let timeline = TimelineStore(appState: state, groupIdHex: group.groupIdHex)
            var calls = ComposerMarmotCalls.live
            calls.sendDraft = { _, _, revision, token in
                if accepted {
                    _ = try await client.sendDraftWithClientToken(accountRef: account.label, revision: revision, attachments: [], clientToken: token)
                }
                throw MarmotKitError.Runtime(details: "delivery failed")
            }
            let composer = ComposerModel(appState: state, groupIdHex: group.groupIdHex, timelineStore: timeline,
                                         marmotCalls: calls)
            composer.canSendMessages = { true }
            let snapshot = ConversationDraftSnapshot(canonicalText: "send once", replyToMessageIdHex: nil, mediaAttachments: [])
            let revision = try await drafts.prepareSend(snapshot, accountRef: account.label, groupIdHex: group.groupIdHex)
            await composer.send("send once", draftRevision: revision) { refresh in
                #expect(refresh == accepted)
                await drafts.finishSend(accountRef: account.label, groupIdHex: group.groupIdHex, accepted: refresh)
            }
            let row = try #require(timeline.timeline.first)
            #expect(timeline.localSendPhase(rowID: row.id) == (accepted ? .accepted : .failed))
            #expect((timeline.failedTransientRecord(rowId: row.id) == nil) == accepted)
            let recovered = await drafts.snapshot(accountRef: account.label, groupIdHex: group.groupIdHex)
            #expect(recovered?.canonicalText == (accepted ? nil : "send once"))
        }
    }

}

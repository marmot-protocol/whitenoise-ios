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

    /// A reopened composer can be edited before it has the saved draft. Those
    /// writes keep the draft's files (MDK would delete one left out), and the
    /// read hands back the edit with the saved attachment. Once the composer has
    /// the draft, removing the attachment removes it.
    @Test func editsBeforeHydrationKeepTheDraftsFiles() async throws {
        let readStarted = TestLatch(), releaseRead = TestLatch()
        try await withLargeAttachmentDraft(readSelectedDraft: { client, ref, selected in
            if selected.draft?.mediaAttachments.contains(where: \.fileBacked) == true {
                readStarted.signal()
                try await releaseRead.wait()
            }
            return try await client.hydrateSelectedDraft(accountRef: ref, selected: selected)
        }) { client, store, ref, chat, video in
            func text(_ value: String) -> ConversationDraftSnapshot {
                ConversationDraftSnapshot(canonicalText: value, replyToMessageIdHex: nil, mediaAttachments: [])
            }
            func saved() async throws -> SelectedMessageDraftContentFfi? {
                try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft
            }
            store.setDraft(text("typed early"), accountRef: ref, groupIdHex: chat, keepsSavedFiles: true)
            // Not the stored draft: it leaves out the file it keeps.
            #expect(await store.snapshot(accountRef: ref, groupIdHex: chat)?.mediaAttachments.map(\.id) == [video.id])
            await store.flush()
            let early = try await saved()
            #expect(early?.content == "typed early")
            #expect(early?.mediaAttachments.map(\.id) == [video.id.uuidString])

            store.setDraft(text(""), accountRef: ref, groupIdHex: chat, keepsSavedFiles: true)
            await store.flush()
            let cleared = try await saved()
            #expect(cleared?.mediaAttachments.map(\.id) == [video.id.uuidString])

            // An edit lands while the composer's read is between chunks. Its
            // write waits for the read (a new revision would fail the next
            // chunk), and the read returns the edit with the saved attachment.
            let load = Task { await store.loadSnapshot(accountRef: ref, groupIdHex: chat, hydratingComposer: true) }
            try await readStarted.wait()
            store.setDraft(text("typed while loading"), accountRef: ref, groupIdHex: chat, keepsSavedFiles: true)
            let written = TestLatch()
            let writes = Task {
                await store.flush()
                written.signal()
            }
            // Bounded on purpose: the write must still be waiting.
            await #expect(throws: (any Error).self) { try await written.wait(timeout: .seconds(2)) }
            releaseRead.signal()
            guard case .loaded(let restored) = await load.value else {
                Issue.record("The composer's read failed")
                return
            }
            await writes.value
            #expect(restored?.canonicalText == "typed while loading")
            #expect(restored?.mediaAttachments.map(\.id) == [video.id])
            #expect(try await saved()?.mediaAttachments.map(\.id) == [video.id.uuidString])

            store.setDraft(text("typed while loading"), accountRef: ref, groupIdHex: chat)
            await store.flush()
            let removed = try await saved()
            #expect(removed?.mediaAttachments.isEmpty == true)
        }
    }

    /// Removing a large attachment just as MDK commits its copy removes it:
    /// the copy's commit can't make the removal look like no change.
    @Test func removingAnAttachmentAsItsCopyCommitsRemovesIt() async throws {
        let committed = TestLatch(), releaseCommit = TestLatch()
        try await withLargeAttachmentDraft(staged: false, stageIntoDraft: { client, ref, revision, attachment, path, control in
            let staged = try await client.stageMessageDraftAttachment(accountRef: ref, revision: revision,
                attachment: attachment, sourcePath: path, control: control)
            committed.signal()
            try await releaseCommit.wait()
            return staged
        }) { client, store, ref, chat, video in
            func caption(_ attachments: [MediaDraftAttachment]) -> ConversationDraftSnapshot {
                ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: attachments)
            }
            store.setDraft(caption([video]), accountRef: ref, groupIdHex: chat)
            await store.flush()  // The caption saves before the copy commits.
            try await committed.wait()
            store.setDraft(caption([]), accountRef: ref, groupIdHex: chat)
            releaseCommit.signal()
            await store.flush()
            let draft = try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft
            #expect(draft?.content == "caption")
            #expect(draft?.mediaAttachments.isEmpty == true)
        }
    }

    /// A chat reopened while a large attachment's copy is still being prepared
    /// reads the draft once the copy lands, so the composer shows the file
    /// rather than a later save deleting it. An edit typed meanwhile doesn't
    /// cancel the copy.
    @Test func aComposerReopenedDuringACopyReadsTheDraftAfterIt() async throws {
        let sourceStarted = TestLatch(), releaseSource = TestLatch(), readCalled = TestLatch()
        try await withLargeAttachmentDraft(staged: false, prepareStagingSource: { attachment in
            sourceStarted.signal()
            try await releaseSource.wait()
            return try await MediaUploadSourceFiles.stage([attachment])
        }, readSelectedDraft: { client, ref, selected in
            readCalled.signal()
            return try await client.hydrateSelectedDraft(accountRef: ref, selected: selected)
        }) { client, store, ref, chat, video in
            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: [video]),
                           accountRef: ref, groupIdHex: chat)
            await store.flush()
            try await sourceStarted.wait()

            let reopened = Task { await store.loadSnapshot(accountRef: ref, groupIdHex: chat, hydratingComposer: true) }
            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption, edited", replyToMessageIdHex: nil, mediaAttachments: []),
                           accountRef: ref, groupIdHex: chat, keepsSavedFiles: true)
            // Bounded on purpose: the read must still be waiting for the copy.
            await #expect(throws: (any Error).self) { try await readCalled.wait(timeout: .seconds(2)) }
            releaseSource.signal()
            guard case .loaded(let restored) = await reopened.value else {
                Issue.record("The composer's read failed")
                return
            }
            #expect(restored?.canonicalText == "caption, edited")
            #expect(restored?.mediaAttachments.map(\.id) == [video.id])
            await store.flush()
            let saved = try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft
            #expect(saved?.content == "caption, edited")
            #expect(saved?.mediaAttachments.map(\.id) == [video.id.uuidString])
        }
    }

    /// A chat reopened while its draft is being sent reads the draft only once
    /// the send settles, so the composer can't restore the message MDK is
    /// sending (and send it again).
    @Test func aComposerReopenedDuringASendReadsTheDraftAfterIt() async throws {
        let readCalled = TestLatch()
        try await withLargeAttachmentDraft(staged: false, readSelectedDraft: { client, ref, selected in
            readCalled.signal()
            return try await client.hydrateSelectedDraft(accountRef: ref, selected: selected)
        }) { client, store, ref, chat, _ in
            let message = ConversationDraftSnapshot(canonicalText: "sent", replyToMessageIdHex: nil, mediaAttachments: [])
            store.setDraft(message, accountRef: ref, groupIdHex: chat)
            await store.flush()
            store.beginQueuedSend(accountRef: ref, groupIdHex: chat)
            store.setDraft(ConversationDraftSnapshot(canonicalText: "", replyToMessageIdHex: nil, mediaAttachments: []),
                           accountRef: ref, groupIdHex: chat)
            let revision = try await store.prepareSend(message, accountRef: ref, groupIdHex: chat)

            let reopened = Task { await store.loadSnapshot(accountRef: ref, groupIdHex: chat, hydratingComposer: true) }
            // Bounded on purpose: the read must still be waiting for the send.
            await #expect(throws: (any Error).self) { try await readCalled.wait(timeout: .seconds(2)) }
            _ = try await client.sendDraftWithClientToken(accountRef: ref, revision: revision,
                attachments: [], clientToken: UUID().uuidString)
            await store.finishSend(accountRef: ref, groupIdHex: chat, accepted: true)
            #expect(await reopened.value == .loaded(nil))
        }
    }

    /// Suspension cancels a composer's read; storage closing under a chunk
    /// already in flight is still a cancelled read (retried on resume), not a
    /// failed one, which would stop keeping the draft's files.
    @Test func aReadCancelledBySuspensionIsNotAFailure() async throws {
        let readStarted = TestLatch()
        try await withLargeAttachmentDraft(readSelectedDraft: { _, _, _ in
            readStarted.signal()
            // The chunk in flight returns once storage closes.
            try? await eventually { Task.isCancelled }
            throw MarmotKitError.StorageClosed(details: "closed")
        }) { client, store, ref, chat, _ in
            let reopened = Task { await store.loadSnapshot(accountRef: ref, groupIdHex: chat, hydratingComposer: true) }
            try await readStarted.wait()
            await store.flush(using: client)
            #expect(await reopened.value == .cancelled)
        }
    }

    /// Suspending the runtime doesn't wait for a large attachment's copy into
    /// the draft, even while the host copy MDK reads from is still being
    /// written: the caption is saved, and the next edit copies it again.
    @Test func suspendingSavesTheCaptionWithoutWaitingForADraftCopy() async throws {
        let sourceStarted = TestLatch(), releaseSource = TestLatch()
        try await withLargeAttachmentDraft(staged: false, prepareStagingSource: { attachment in
            sourceStarted.signal()
            // Outlasts the wait below, so a save held behind it fails the test.
            try await releaseSource.wait(timeout: .seconds(300))
            return try await MediaUploadSourceFiles.stage([attachment])
        }) { client, store, ref, chat, video in
            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption", replyToMessageIdHex: nil, mediaAttachments: [video]),
                           accountRef: ref, groupIdHex: chat)
            try await sourceStarted.wait()
            let saved = TestLatch()
            let suspension = Task {
                await store.flush(using: client)
                saved.signal()
            }
            try await saved.wait()
            await suspension.value
            #expect(try await client.selectedMessageDraft(accountRef: ref, groupIdHex: chat).draft?.content == "caption")
            #expect(!store.sendsThroughDraft([video], accountRef: ref, groupIdHex: chat))

            releaseSource.signal()
            store.setDraft(ConversationDraftSnapshot(canonicalText: "caption, edited", replyToMessageIdHex: nil, mediaAttachments: [video]),
                           accountRef: ref, groupIdHex: chat)
            try await eventually { store.sendsThroughDraft([video], accountRef: ref, groupIdHex: chat) }
        }
    }

    /// A runtime with one chat whose draft holds `video` (over the inline
    /// draft limit) as a file, unless `staged` is false.
    private func withLargeAttachmentDraft(
        staged: Bool = true,
        prepareStagingSource: @escaping @Sendable (MediaDraftAttachment) async throws -> MediaUploadSourceFiles = {
            try await MediaUploadSourceFiles.stage([$0])
        },
        readSelectedDraft: @escaping @MainActor (MarmotClient, String, SelectedMessageDraftFfi) async throws -> MessageDraftFfi? = {
            try await $0.hydrateSelectedDraft(accountRef: $1, selected: $2)
        },
        stageIntoDraft: @escaping @MainActor (
            MarmotClient, String, MessageDraftRevisionFfi, MediaDraftAttachment, String, MediaFileTransferControlFfi
        ) async throws -> SelectedMessageDraftFfi = {
            try await $0.stageMessageDraftAttachment(accountRef: $1, revision: $2, attachment: $3, sourcePath: $4, control: $5)
        },
        _ body: (MarmotClient, ConversationDraftStore, String, String, MediaDraftAttachment) async throws -> Void
    ) async throws {
        try await withTestClient { client in
            let defaults = try #require(UserDefaults(suiteName: "DraftClaimTests.\(UUID())"))
            let store = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                               prepareStagingSource: prepareStagingSource, readSelectedDraft: readSelectedDraft,
                                               stageIntoDraft: stageIntoDraft)
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

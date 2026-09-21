import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct ConversationWindowBindingTests {
    @Test func revisionedDraftsAndWindowCancellationUsePublishedBinary() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start(
            "Conversation window or draft operation did not finish", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Window test", memberRefs: [],
                options: CreateGroupOptionsFfi(description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let empty = try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex)
            let first = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: empty.revision,
                snapshot: ConversationDraftSnapshot(canonicalText: "first", replyToMessageIdHex: nil, mediaAttachments: []))
            let newer = try await client.saveMessageDraftIfRevision(accountRef: account.label, revision: first.revision,
                snapshot: ConversationDraftSnapshot(canonicalText: "newer typing", replyToMessageIdHex: nil, mediaAttachments: []))
            do {
                _ = try await client.sendMessageDraft(accountRef: account.label, revision: first.revision, attachments: [])
                Issue.record("Sending an old draft revision must fail")
            } catch MarmotKitError.MessageDraftRevisionConflict {}
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "newer typing")
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
            let initial = try #require(window.snapshot())
            #expect(window.snapshot() == nil)
            #expect(initial.draft.draft?.content == "newer typing")
            let reader = Task { while try await window.nextCancellable() != nil {} }
            await Task.yield()
            reader.cancel()
            await #expect(throws: CancellationError.self) { try await reader.value }
            await window.cancel()
            #expect(try await window.next() == nil)
            let cleared = try await client.clearMessageDraftIfRevision(accountRef: account.label, revision: newer.revision)
            #expect(cleared.draft == nil)
            let blocks = try client.marmot.subscribeBlockedUsers(accountRef: account.label)
            #expect(blocks.snapshot()?.users.isEmpty == true)
            let blockReader = Task { while try await blocks.nextCancellable() != nil {} }
            await Task.yield()
            blockReader.cancel()
            await #expect(throws: CancellationError.self) { try await blockReader.value }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
    @Test func draftStorePreservesTypingDuringSendAndRequiresConflictResolution() async throws {
        let client = try MarmotClient.testClient()
        let defaults = try #require(UserDefaults(suiteName: "DraftWindowTests.\(UUID())"))
        let store = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let state = AppState(client: client, notifications: .shared, conversationDraftStore: store,
            accountDefaults: defaults, erasureDefaults: defaults)
        state.setPhase(.ready)
        let watchdog = MarmotFixtureWatchdog.start(
            "Draft store send did not complete", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Draft store", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let key = ConversationDraftKey(accountRef: account.label, groupIdHex: group.groupIdHex)
            func draft(_ text: String) -> ConversationDraftSnapshot {
                ConversationDraftSnapshot(canonicalText: text, replyToMessageIdHex: nil, mediaAttachments: [])
            }
            let revision = try await store.prepareSend(draft("send me"), accountRef: account.label, groupIdHex: group.groupIdHex)
            store.setDraft(draft(""), accountRef: account.label, groupIdHex: group.groupIdHex)
            store.setDraft(draft("next message"), accountRef: account.label, groupIdHex: group.groupIdHex)
            await store.flush()
            #expect(try await client.selectedMessageDraft(accountRef: account.label, groupIdHex: group.groupIdHex).draft?.content == "send me")
            _ = try await client.sendMessageDraft(accountRef: account.label, revision: revision, attachments: [])
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
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func draftSendStatusDistinguishesAcceptedFromRejectedAdmission(accepted: Bool) async throws {
        let client = try MarmotClient.testClient()
        let defaults = try #require(UserDefaults(suiteName: "DraftSendFailureTests.\(UUID())"))
        let drafts = ConversationDraftStore(legacyFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let state = AppState(client: client, notifications: .shared, conversationDraftStore: drafts,
            accountDefaults: defaults, erasureDefaults: defaults)
        state.setPhase(.ready)
        let watchdog = MarmotFixtureWatchdog.start("Draft send recovery did not complete", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: ["wss://relay.invalid.test"], bootstrapRelays: ["wss://relay.invalid.test"]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Send recovery", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            state.activeAccountRef = account.label
            let timeline = TimelineStore(appState: state, groupIdHex: group.groupIdHex)
            let composer = ComposerModel(appState: state, groupIdHex: group.groupIdHex, timelineStore: timeline)
            composer.canSendMessages = { true }
            let snapshot = ConversationDraftSnapshot(canonicalText: "send once", replyToMessageIdHex: nil, mediaAttachments: [])
            let revision = try await drafts.prepareSend(snapshot, accountRef: account.label, groupIdHex: group.groupIdHex)
            composer.sendTextForTesting = { _, _, _, _, token in
                if accepted {
                    _ = try await client.sendDraftWithClientToken(accountRef: account.label, revision: revision, attachments: [], clientToken: token)
                }
                throw MarmotKitError.Runtime(details: "delivery failed")
            }
            await composer.send("send once", draftRevision: revision) { refresh in
                #expect(refresh == accepted)
                await drafts.finishSend(accountRef: account.label, groupIdHex: group.groupIdHex, accepted: refresh)
            }
            let row = try #require(timeline.timeline.first)
            #expect(timeline.localSendPhase(rowID: row.id) == (accepted ? .accepted : .failed))
            #expect((timeline.failedTransientRecord(rowId: row.id) == nil) == accepted)
            let recovered = await drafts.snapshot(accountRef: account.label, groupIdHex: group.groupIdHex)
            #expect(recovered?.canonicalText == (accepted ? nil : "send once"))
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

}

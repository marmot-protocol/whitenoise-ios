import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .tags(.runtime), .marmotRuntimeConcurrencyLimit)
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
        }
    }

}

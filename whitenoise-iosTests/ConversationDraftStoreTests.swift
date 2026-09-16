import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct ConversationDraftStoreTests {
    @Test func groupResetDrainsWritesAndBlocksLateComposerPersistence() async {
        let persistence = DraftPersistenceProbe()
        let store = ConversationDraftStore(persistence: persistence)
        var release: CheckedContinuation<Void, Never>?
        persistence.beforePersist = { await withCheckedContinuation { release = $0 } }
        store.setDraft(textSnapshot("before reset"), accountRef: "account", groupIdHex: "group")
        let write = Task { await store.flush() }
        while release == nil { await Task.yield() }
        var prepared = false
        let reset = Task {
            await store.pauseForGroupReset(accountRef: "account", groupIdHex: "group")
            prepared = true
        }
        await Task.yield()
        #expect(!prepared)
        store.setDraft(textSnapshot("late view callback"), accountRef: "account", groupIdHex: "group")
        release?.resume()
        await write.value
        await reset.value
        #expect(prepared)
        store.finishGroupReset(accountRef: "account", groupIdHex: "group", succeeded: true)
        #expect(store.summary(accountRef: "account", groupIdHex: "group") == nil)
        #expect(await store.snapshot(accountRef: "account", groupIdHex: "group") == nil)
        #expect(persistence.persistCount == 1)
        // A newly opened, freshly joined group can draft again.
        persistence.beforePersist = nil
        store.setDraft(textSnapshot("after rejoin"), accountRef: "account", groupIdHex: "group")
        await store.flush()
        #expect(persistence.draft(accountRef: "account", groupIdHex: "group")?.content == "after rejoin")
    }

    @Test func failedGroupResetResumesTheUnsavedDraft() async {
        let persistence = DraftPersistenceProbe()
        let store = ConversationDraftStore(persistence: persistence)
        store.setDraft(textSnapshot("keep this"), accountRef: "account", groupIdHex: "group")
        await store.pauseForGroupReset(accountRef: "account", groupIdHex: "group")
        store.finishGroupReset(accountRef: "account", groupIdHex: "group", succeeded: false)
        await store.flush()
        #expect(persistence.draft(accountRef: "account", groupIdHex: "group")?.content == "keep this")
    }

    @Test func draftsPersistAcrossStoreInstancesAndStayAccountGroupScoped() async {
        let persistence = DraftPersistenceProbe()
        let first = ConversationDraftStore(persistence: persistence)
        first.setDraft(
            textSnapshot("first account, first group"),
            accountRef: "account-a",
            groupIdHex: "group-a"
        )
        first.setDraft(
            textSnapshot("first account, second group"),
            accountRef: "account-a",
            groupIdHex: "group-b"
        )
        first.setDraft(
            textSnapshot("second account"),
            accountRef: "account-b",
            groupIdHex: "group-a"
        )
        await first.flush()

        let restored = ConversationDraftStore(persistence: persistence)
        await restored.loadIfNeeded(accountRef: "account-a")
        await restored.loadIfNeeded(accountRef: "account-b")

        #expect(
            await restored.snapshot(accountRef: "account-a", groupIdHex: "group-a")
                == textSnapshot("first account, first group")
        )
        #expect(
            await restored.snapshot(accountRef: "account-a", groupIdHex: "group-b")
                == textSnapshot("first account, second group")
        )
        #expect(
            await restored.snapshot(accountRef: "account-b", groupIdHex: "group-a")
                == textSnapshot("second account")
        )
        #expect(await restored.snapshot(accountRef: "account-b", groupIdHex: "group-b") == nil)
    }

    @Test func bindingRoundTripPreservesReplyAndAttachmentPlaintext() async throws {
        let persistence = DraftPersistenceProbe()
        let attachment = MediaDraftAttachment(
            id: UUID(),
            fileName: "notes.txt",
            mediaType: "text/plain",
            data: Data("private attachment".utf8),
            dim: nil,
            thumbhash: "thumbhash",
            durationSeconds: 1.5,
            waveformSamples: [0.1, 0.4, 0.2]
        )
        let snapshot = ConversationDraftSnapshot(
            canonicalText: "reply with a file",
            replyToMessageIdHex: hex("ab"),
            mediaAttachments: [attachment]
        )

        let first = ConversationDraftStore(persistence: persistence)
        first.setDraft(snapshot, accountRef: "account", groupIdHex: "group")
        await first.flush()

        let restored = ConversationDraftStore(persistence: persistence)
        let hydrated = try #require(
            await restored.snapshot(accountRef: "account", groupIdHex: "group")
        )
        #expect(hydrated == snapshot)
        #expect(restored.summary(accountRef: "account", groupIdHex: "group")?.mediaAttachments.first?
            .plaintextSize == UInt64(attachment.data.count))
    }

    @Test func mentionIdentityRoundTripsThroughCanonicalBindingText() throws {
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: hex("11")
        ))
        let displayState = ComposerMentionDraftState(
            draft: "ask @Alex",
            selectedMentions: [
                ComposerMentionSelection(
                    utf16Location: "ask ".utf16.count,
                    utf16Length: "@Alex".utf16.count,
                    displayName: "Alex",
                    npub: npub
                ),
            ]
        )

        #expect(displayState.canonicalText == "ask @\(npub)")

        let restored = ComposerMentionDraftState(
            canonicalText: displayState.canonicalText,
            mentionDisplayName: { _ in "Alex" }
        )
        #expect(restored == displayState)
    }

    @Test func legacyJSONIsImportedIntoTheBindingAndRemoved() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("22")))
        let legacyDocument = """
        {
          "version": 1,
          "entries": [
            {
              "key": { "accountRef": "account", "groupIdHex": "group" },
              "text": "ask @Alex",
              "mentions": [
                {
                  "utf16Location": 4,
                  "utf16Length": 5,
                  "displayName": "Alex",
                  "npub": "\(npub)"
                }
              ],
              "updatedAt": 1
            }
          ]
        }
        """
        try #require(legacyDocument.data(using: .utf8)).write(to: fixture.file)
        let persistence = DraftPersistenceProbe()
        let store = ConversationDraftStore(
            persistence: persistence,
            legacyFileURL: fixture.file
        )

        async let firstLoad: Void = store.loadIfNeeded(accountRef: "account")
        async let secondLoad: Void = store.loadIfNeeded(accountRef: "account")
        _ = await (firstLoad, secondLoad)

        #expect(persistence.summaryLoadCount == 1)
        #expect(persistence.persistCount == 1)
        #expect(
            await store.snapshot(accountRef: "account", groupIdHex: "group")?.canonicalText
                == "ask @\(npub)"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func blankDraftDeletesTheBindingRowWhileReplyOnlyDraftPersists() async {
        let persistence = DraftPersistenceProbe()
        let store = ConversationDraftStore(persistence: persistence)
        store.setDraft(
            ConversationDraftSnapshot(
                canonicalText: "",
                replyToMessageIdHex: hex("cd"),
                mediaAttachments: []
            ),
            accountRef: "account",
            groupIdHex: "group"
        )
        await store.flush()
        #expect(persistence.draft(accountRef: "account", groupIdHex: "group") != nil)

        store.setDraft(
            ConversationDraftSnapshot(
                canonicalText: " \n\t ",
                replyToMessageIdHex: nil,
                mediaAttachments: []
            ),
            accountRef: "account",
            groupIdHex: "group"
        )
        await store.flush()

        #expect(persistence.draft(accountRef: "account", groupIdHex: "group") == nil)
        #expect(persistence.deleteCount == 1)
    }

    @Test func flushPersistsTheLatestDebouncedRevisionImmediately() async {
        let persistence = DraftPersistenceProbe()
        let store = ConversationDraftStore(persistence: persistence)
        store.setDraft(textSnapshot("first"), accountRef: "account", groupIdHex: "group")
        store.setDraft(textSnapshot("last keystrokes"), accountRef: "account", groupIdHex: "group")

        await store.flush()

        #expect(
            persistence.draft(accountRef: "account", groupIdHex: "group")?.content
                == "last keystrokes"
        )
        #expect(persistence.persistCount == 1)
    }

    @Test func chatListPreviewProjectsCanonicalMentionsAndSanitizesText() throws {
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("33")))
        let preview = ConversationDraftPreview.text(
            from: MessageDraftSummaryFfi(
                groupIdHex: "group",
                content: "  First @\(npub)\u{202E}\nsecond\u{200B}  ",
                replyToMessageIdHex: nil,
                mediaAttachments: [],
                createdAtMs: 1,
                updatedAtMs: 1
            ),
            mentionDisplayName: { _ in "Alice" }
        )

        #expect(preview == "First @Alice second")
    }

    private func textSnapshot(_ text: String) -> ConversationDraftSnapshot {
        ConversationDraftSnapshot(
            canonicalText: text,
            replyToMessageIdHex: nil,
            mediaAttachments: []
        )
    }

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }

    private func makeFixture() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ConversationDraftStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        return (root, root.appendingPathComponent("drafts.json"))
    }
}

@MainActor
private final class DraftPersistenceProbe: ConversationDraftPersistence {
    private var drafts: [ConversationDraftKey: MessageDraftFfi] = [:]
    private(set) var summaryLoadCount = 0
    private(set) var persistCount = 0
    var beforePersist: (() async -> Void)?
    private(set) var deleteCount = 0
    private var clock: Int64 = 0

    func loadMessageDraftSummaries(accountRef: String) async throws -> [MessageDraftSummaryFfi] {
        summaryLoadCount += 1
        return drafts.compactMap { key, draft in
            guard key.accountRef == accountRef else { return nil }
            return MessageDraftSummaryFfi(
                groupIdHex: draft.groupIdHex,
                content: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex,
                mediaAttachments: draft.mediaAttachments.map {
                    MessageDraftAttachmentSummaryFfi(
                        id: $0.id,
                        fileName: $0.fileName,
                        mediaType: $0.mediaType,
                        plaintextSize: UInt64($0.plaintext.count)
                    )
                },
                createdAtMs: draft.createdAtMs,
                updatedAtMs: draft.updatedAtMs
            )
        }
    }

    func loadMessageDraft(
        accountRef: String,
        groupIdHex: String
    ) async throws -> MessageDraftFfi? {
        draft(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func persistMessageDraft(
        accountRef: String,
        groupIdHex: String,
        snapshot: ConversationDraftSnapshot
    ) async throws -> MessageDraftFfi {
        persistCount += 1
        await beforePersist?()
        clock += 1
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        let saved = MessageDraftFfi(
            groupIdHex: groupIdHex,
            content: snapshot.canonicalText,
            replyToMessageIdHex: snapshot.replyToMessageIdHex,
            mediaAttachments: snapshot.mediaAttachments.map(\.messageDraftAttachment),
            createdAtMs: drafts[key]?.createdAtMs ?? clock,
            updatedAtMs: clock
        )
        drafts[key] = saved
        return saved
    }

    func deletePersistedMessageDraft(accountRef: String, groupIdHex: String) async throws {
        deleteCount += 1
        drafts[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)] = nil
    }

    func draft(accountRef: String, groupIdHex: String) -> MessageDraftFfi? {
        drafts[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
    }
}

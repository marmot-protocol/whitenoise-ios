import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct SignUpDraftStoreTests {
    @Test func draftRoundTripsWithoutStaleWritesUndoingCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .creating
        draft.displayName = "Alice"
        draft.about = "Hello"
        draft.photo = .init(data: Data([1, 2, 3]), mediaType: "image/jpeg", dim: "1024x1024", thumbhash: nil)
        let old = draft
        draft.revision = 2
        draft.displayName = "New name"
        try await store.save(draft)
        try await store.save(old)
        let reopened = SignUpDraftStore(directory: directory)
        #expect(try await reopened.load() == draft)
        try await store.clear(id: draft.id)
        draft.revision = 3
        try await store.save(draft)
        #expect(try await reopened.load() == nil)
    }

    #if targetEnvironment(simulator)
    @Test(.disabled("Data Protection attributes require a physical iOS device."))
    #else
    @Test
    #endif
    func submittedDraftAndDirectoryUseCompleteFileProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.stage = .creating
        try await store.save(draft)
        for url in [directory, directory.appendingPathComponent("draft.json")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        }
    }

    @Test func unsubmittedFormIsNotSavedAndLegacyDraftIsDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SignUpDraftStore(directory: directory)
        var draft = SignUpDraft()
        draft.displayName = "Alice"
        draft.photo = .init(data: Data([1, 2, 3]), mediaType: "image/jpeg", dim: nil, thumbhash: nil)
        try await store.save(draft)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        // Reproduce the file written by the previous autosave behavior.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("draft.json"))
        #expect(try await store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func corruptDraftIsNotSilentlyDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("draft.json")
        try Data("broken".utf8).write(to: file)
        let store = SignUpDraftStore(directory: directory)
        await #expect(throws: SignUpDraftStore.Failure.self) { try await store.load() }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func recoveryNeverInfersOwnershipFromNewAccounts() throws {
        var draft = SignUpDraft()
        draft.baselineAccountIDs = ["existing"]
        #expect(try draft.recoveredAccount(in: [account("existing")]) == nil)
        for accounts in [[account("existing"), account("imported")],
                         [account("imported"), account("another")]] {
            #expect(throws: SignUpDraftStore.Failure.ambiguousAccount) {
                try draft.recoveredAccount(in: accounts)
            }
        }
        #expect(!draft.blocksActivation(accountID: "imported"))
        draft.accountID = "created"
        #expect(try draft.recoveredAccount(in: [account("created"), account("imported")])?.accountIdHex == "created")
        #expect(draft.blocksActivation(accountID: "created"))
        #expect(!draft.blocksActivation(accountID: "imported"))
        #expect(throws: SignUpDraftStore.Failure.accountUnavailable) {
            try draft.recoveredAccount(in: [account("imported")])
        }
    }

    @Test func completionReconciliationRequiresAllEnteredDetails() {
        var draft = SignUpDraft()
        draft.displayName = "Alice"
        draft.about = "Hello"
        draft.uploadedPhotoURL = "https://example.com/photo.jpg"
        let matching = UserProfileMetadataFfi(name: "Alice", displayName: "Alice", about: "Hello",
                                             picture: draft.uploadedPhotoURL, banner: nil, nip05: nil, lud16: nil)
        #expect(draft.matchesPublishedProfile(matching))
        var stale = matching
        stale.picture = nil
        #expect(!draft.matchesPublishedProfile(stale))
        stale = matching
        stale.about = "Old bio"
        #expect(!draft.matchesPublishedProfile(stale))
    }

    private func account(_ id: String) -> AccountSummaryFfi {
        .init(label: id, accountIdHex: id, localSigning: true, externalSigning: false, signedOut: false, running: true)
    }
}

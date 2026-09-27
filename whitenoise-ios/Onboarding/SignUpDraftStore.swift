import Foundation
import MarmotKit

nonisolated struct SignUpDraft: Codable, Equatable, Sendable {
    enum Stage: String, Codable { case editing, creating, setup, uploading, publishing, completed, resetting }
    struct Photo: Codable, Equatable, Sendable {
        var data: Data
        var mediaType: String
        var dim: String?
        var thumbhash: String?
    }

    var version = 1
    var id = UUID()
    var revision = 0
    var displayName = ""
    var about = ""
    var photo: Photo?
    var uploadedPhotoURL: String?
    var accountRef: String?
    var accountID: String?
    var baselineAccountIDs: [String]?
    var stage: Stage = .editing

    var requiresRecovery: Bool {
        stage != .editing || baselineAccountIDs != nil || accountID != nil
    }

    func matchesPublishedProfile(_ profile: UserProfileMetadataFfi) -> Bool {
        let name = ContentSanitizer.displayName(displayName)
        return profile.name == name && profile.displayName == name
            && profile.about == ContentSanitizer.multilineText(about)
            && profile.picture == uploadedPhotoURL
    }

    func blocksActivation(accountID: String) -> Bool {
        if let pendingID = self.accountID { return pendingID == accountID }
        guard let baselineAccountIDs else { return false }
        // Creation may have committed in MDK before its response reaches Swift.
        return !baselineAccountIDs.contains(accountID)
    }

    func recoveredAccount(in accounts: [AccountSummaryFfi]) throws -> AccountSummaryFfi? {
        if let accountID {
            guard let account = accounts.first(where: { $0.accountIdHex == accountID && !$0.signedOut }) else {
                if stage == .resetting { return nil }
                throw SignUpDraftStore.Failure.accountUnavailable
            }
            return account
        }
        guard let baselineAccountIDs else { return nil }
        let candidates = accounts.filter { !baselineAccountIDs.contains($0.accountIdHex) && !$0.signedOut }
        guard candidates.count <= 1 else { throw SignUpDraftStore.Failure.ambiguousAccount }
        return candidates.first
    }
}

/// Stores an unfinished submission, never account secrets or MDK state.
actor SignUpDraftStore {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadable, accountUnavailable, ambiguousAccount, writeFailed
        var errorDescription: String? { L10n.string("Couldn’t restore your unfinished sign-up. Please try again.") }
    }

    private let directory: URL
    private var lastRevision = -1
    private var currentID: UUID?
    private var closedIDs: Set<UUID> = []

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let defaultDirectory = isTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("SignUpDraft-\(UUID())")
            : base.appendingPathComponent("SignUpDraft", isDirectory: true)
        self.directory = directory ?? defaultDirectory
    }

    func load() throws -> SignUpDraft? {
        let file = directory.appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16 * 1024 * 1024 else { throw Failure.unreadable }
        let draft: SignUpDraft
        do { draft = try JSONDecoder().decode(SignUpDraft.self, from: Data(contentsOf: file)) }
        catch { throw Failure.unreadable }
        guard draft.version == 1 else { throw Failure.unreadable }
        currentID = draft.id
        lastRevision = max(lastRevision, draft.revision)
        // Earlier builds persisted unsubmitted forms. Discard those on upgrade.
        guard draft.requiresRecovery else {
            try clear(id: draft.id)
            return nil
        }
        return draft
    }

    func save(_ draft: SignUpDraft) throws {
        guard draft.requiresRecovery, !closedIDs.contains(draft.id) else { return }
        if currentID == draft.id, draft.revision <= lastRevision { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let data = try JSONEncoder().encode(draft)
        guard data.count <= 16 * 1024 * 1024 else { throw Failure.unreadable }
        try data.write(to: directory.appendingPathComponent("draft.json"), options: [.atomic, .completeFileProtection])
        currentID = draft.id
        lastRevision = draft.revision
    }

    func clear(id: UUID) throws {
        guard currentID == nil || currentID == id else { return }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        closedIDs.insert(id)
        currentID = nil
        lastRevision = -1
    }
}

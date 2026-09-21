import Foundation
import MarmotKit
import Observation
import OSLog

nonisolated struct ConversationDraftKey: Hashable, Codable, Sendable {
    let accountRef: String
    let groupIdHex: String
}

nonisolated struct ConversationDraftSnapshot: Equatable {
    let canonicalText: String
    let replyToMessageIdHex: String?
    let mediaAttachments: [MediaDraftAttachment]
}

nonisolated enum ConversationDraftPreview {
    static let maximumLength = 140

    static func preparedText(
        _ draft: ChatListDraftPreviewFfi,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        let displayed = CanonicalMentionDisplayProjection.project(draft.text) { npub in
            mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
        }.text
        if let text = ContentSanitizer.singleLine(displayed, maxLength: maximumLength) { return text }
        if draft.attachmentCount > 1 {
            return L10n.plural("📎 %lld attachments", Int64(clamping: draft.attachmentCount))
        }
        switch draft.attachmentKind {
        case .photo: return L10n.string("Photo")
        case .video: return L10n.string("Video")
        case .audio: return L10n.string("Audio")
        case .file, .mixed, nil: return L10n.string("Attachment")
        }
    }

    static func text(
        from summary: MessageDraftSummaryFfi?,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String? {
        guard let summary else { return nil }
        let displayed = CanonicalMentionDisplayProjection.project(summary.content) { npub in
            mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
        }.text
        if let text = ContentSanitizer.singleLine(displayed, maxLength: maximumLength) {
            return text
        }

        let fileNames = summary.mediaAttachments.compactMap {
            ContentSanitizer.compactSingleLine(
                $0.fileName.trimmingCharacters(in: .whitespacesAndNewlines),
                maxLength: MessageSemantics.maxImetaFileNameBytes
            )
        }
        if fileNames.count == 1 {
            return ContentSanitizer.singleLine(
                "📎 \(fileNames[0])",
                maxLength: maximumLength
            )
        }
        if fileNames.count > 1 {
            return L10n.plural("📎 %lld attachments", Int64(fileNames.count))
        }
        if summary.replyToMessageIdHex != nil {
            return L10n.string("Reply")
        }
        return nil
    }
}

@MainActor
protocol ConversationDraftPersistence: AnyObject {
    func loadMessageDraftSummaries(accountRef: String) async throws -> [MessageDraftSummaryFfi]
    func loadMessageDraft(accountRef: String, groupIdHex: String) async throws -> MessageDraftFfi?
    func persistMessageDraft(
        accountRef: String,
        groupIdHex: String,
        snapshot: ConversationDraftSnapshot
    ) async throws -> MessageDraftFfi
    func deletePersistedMessageDraft(accountRef: String, groupIdHex: String) async throws
}

private nonisolated struct LegacyConversationDraftMention: Codable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
    let displayName: String
    let npub: String
}

private nonisolated struct LegacyConversationDraftEntry: Codable, Sendable {
    let key: ConversationDraftKey
    let text: String
    let mentions: [LegacyConversationDraftMention]
    let updatedAt: UInt64

    private enum CodingKeys: String, CodingKey {
        case key
        case text
        case mentions
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ConversationDraftKey.self, forKey: .key)
        text = try container.decode(String.self, forKey: .text)
        mentions = try container.decodeIfPresent(
            [LegacyConversationDraftMention].self,
            forKey: .mentions
        ) ?? []
        updatedAt = try container.decode(UInt64.self, forKey: .updatedAt)
    }
}

private nonisolated struct LegacyConversationDraftDocument: Codable, Sendable {
    let version: Int
    let entries: [LegacyConversationDraftEntry]
}

/// Reads the former protected JSON draft file only long enough to import it
/// into Marmot. Successfully migrated rows are removed; the file disappears
/// once no legacy rows remain.
private actor LegacyConversationDraftFile {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func entries(accountRef: String) -> [LegacyConversationDraftEntry] {
        load().filter { $0.key.accountRef == accountRef }
    }

    func remove(key: ConversationDraftKey) {
        let remaining = load().filter { $0.key != key }
        guard !remaining.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let document = LegacyConversationDraftDocument(version: 1, entries: remaining)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func load() -> [LegacyConversationDraftEntry] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(
                  LegacyConversationDraftDocument.self,
                  from: data
              ),
              document.version == 1
        else { return [] }
        return document.entries
    }
}

/// MainActor projection and debouncer for Marmot's encrypted composer-draft
/// store. Attachment plaintext lives only in the selected conversation and in
/// Marmot's SQLCipher database; chat-list rows use metadata-only summaries.
@MainActor
@Observable
final class ConversationDraftStore {
    static let saveDebounceNanoseconds: UInt64 = 250_000_000
    private nonisolated static let maximumCanonicalTextLength =
        ContentSanitizer.maxMessageLength * 64
    private static let logger = Logger(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "ConversationDrafts"
    )

    private enum PendingOperation: Equatable {
        case save(ConversationDraftSnapshot)
        case delete
    }

    private struct PendingWrite: Equatable {
        let revision: UInt64
        let operation: PendingOperation
    }

    private var summaries: [ConversationDraftKey: MessageDraftSummaryFfi] = [:]
    private(set) var generation = 0

    @ObservationIgnored private weak var persistence: ConversationDraftPersistence?
    @ObservationIgnored private let legacyFile: LegacyConversationDraftFile
    @ObservationIgnored private var loadedAccounts = Set<String>()
    @ObservationIgnored private var loadTasks: [
        String: Task<[MessageDraftSummaryFfi], Error>
    ] = [:]
    @ObservationIgnored private var pendingWrites: [ConversationDraftKey: PendingWrite] = [:]
    @ObservationIgnored private var saveTasks: [ConversationDraftKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var resetPausedKeys: Set<ConversationDraftKey> = []
    @ObservationIgnored private var resetKeys: Set<ConversationDraftKey> = []
    @ObservationIgnored private var activeWrites: [ConversationDraftKey: Int] = [:]
    @ObservationIgnored private var resetWaiters: [ConversationDraftKey: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var selections: [ConversationDraftKey: SelectedMessageDraftFfi] = [:]
    @ObservationIgnored private var sendingKeys: Set<ConversationDraftKey> = []
    @ObservationIgnored private var suppressEmptyAfterSendKeys: Set<ConversationDraftKey> = []
    @ObservationIgnored private var editedWhileSending: Set<ConversationDraftKey> = []
    private(set) var loadErrorKeys: Set<ConversationDraftKey> = []
    private(set) var conflictedKeys: Set<ConversationDraftKey> = []

    func receiveSelection(_ selection: SelectedMessageDraftFfi, accountRef: String, groupIdHex: String) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        // Live metadata must not advance the write token behind an unchanged composer.
        // Hydration, successful writes and explicit conflict resolution adopt revisions.
        guard selections[key] == nil, pendingWrites[key] == nil, activeWrites[key, default: 0] == 0,
              !sendingKeys.contains(key), !conflictedKeys.contains(key) else { return }
        selections[key] = selection
    }

    func resolveConflict(accountRef: String, groupIdHex: String, keepLocal: Bool) async throws {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard let state = persistence as? AppState else { return }
        let client = try state.currentMarmotClient()
        let fresh = try await client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
        selections[key] = fresh
        conflictedKeys.remove(key)
        if keepLocal { scheduleSave(for: key) }
        else {
            pendingWrites[key] = nil
            saveTasks.removeValue(forKey: key)?.cancel()
            summaries[key] = Self.summary(for: fresh)
            generation &+= 1
        }
    }

    /// Claims the conversation's send slot synchronously, at the Send tap.
    ///
    /// The composer clears immediately so its bubble can be staged, and that
    /// empty write must not delete the draft the queued submission still has to
    /// claim by revision. Everything the user types afterwards goes through the
    /// ordinary edited-while-sending path and is restored by `finishSend`.
    func beginQueuedSend(accountRef: String, groupIdHex: String) {
        suppressEmptyAfterSendKeys.insert(ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex))
    }

    func prepareSend(_ snapshot: ConversationDraftSnapshot, accountRef: String, groupIdHex: String) async throws -> MessageDraftRevisionFfi {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard !sendingKeys.contains(key), !conflictedKeys.contains(key) else { throw MarmotKitError.MessageDraftRevisionConflict }
        setDraft(snapshot, accountRef: accountRef, groupIdHex: groupIdHex)
        await flush(key: key, using: nil)
        guard pendingWrites[key] == nil, let selection = selections[key], selection.draft != nil else {
            throw MarmotKitError.MessageDraftRevisionConflict
        }
        sendingKeys.insert(key)
        suppressEmptyAfterSendKeys.insert(key)
        activeWrites[key, default: 0] += 1
        editedWhileSending.remove(key)
        return selection.revision
    }

    func finishSend(accountRef: String, groupIdHex: String, accepted: Bool) async {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        if accepted, let state = persistence as? AppState,
           let client = try? state.currentMarmotClient(),
           let selected = try? await client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex) {
            selections[key] = selected
            if pendingWrites[key] == nil {
                summaries[key] = Self.summary(for: selected)
                generation &+= 1
            }
        }
        if sendingKeys.remove(key) != nil {
            activeWrites[key, default: 0] -= 1
            if activeWrites[key] == 0 {
                activeWrites[key] = nil
                resetWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
            }
        }
        editedWhileSending.remove(key)
        if pendingWrites[key] != nil { scheduleSave(for: key) }
    }

    @ObservationIgnored private var nextRevision: UInt64 = 0

    init(
        persistence: ConversationDraftPersistence? = nil,
        legacyFileURL: URL? = nil
    ) {
        self.persistence = persistence
        self.legacyFile = LegacyConversationDraftFile(
            url: legacyFileURL ?? Self.defaultLegacyFileURL()
        )
    }

    isolated deinit {
        for task in loadTasks.values {
            task.cancel()
        }
        for task in saveTasks.values {
            task.cancel()
        }
    }

    func configure(persistence: ConversationDraftPersistence) {
        if self.persistence == nil {
            self.persistence = persistence
        }
    }

    func loadIfNeeded(accountRef: String) async {
        guard !loadedAccounts.contains(accountRef), let persistence else { return }
        let task: Task<[MessageDraftSummaryFfi], Error>
        if let existing = loadTasks[accountRef] {
            task = existing
        } else {
            task = Task {
                try await persistence.loadMessageDraftSummaries(accountRef: accountRef)
            }
            loadTasks[accountRef] = task
        }

        do {
            let loaded = try await task.value
            loadTasks[accountRef] = nil
            guard !loadedAccounts.contains(accountRef) else { return }
            applyLoadedSummaries(loaded, accountRef: accountRef)
            loadedAccounts.insert(accountRef)
            await migrateLegacyDrafts(accountRef: accountRef)
        } catch is CancellationError {
            loadTasks[accountRef] = nil
        } catch {
            loadTasks[accountRef] = nil
            Self.logger.error("Failed to load encrypted composer draft summaries")
        }
    }

    func summary(accountRef: String, groupIdHex: String) -> MessageDraftSummaryFfi? {
        summaries[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
    }

    func snapshot(accountRef: String, groupIdHex: String) async -> ConversationDraftSnapshot? {
        await loadIfNeeded(accountRef: accountRef)
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard !resetPausedKeys.contains(key), !resetKeys.contains(key) else { return nil }
        if let pending = pendingWrites[key] {
            switch pending.operation {
            case .save(let snapshot):
                return snapshot
            case .delete:
                return nil
            }
        }
        guard let persistence else { return nil }
        loadErrorKeys.remove(key)
        do {
            let loaded: MessageDraftFfi?
            if let state = persistence as? AppState {
                let client = try state.currentMarmotClient()
                let selected = try await client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
                selections[key] = selected
                loaded = try await client.hydrateSelectedDraft(accountRef: accountRef, selected: selected)
            } else {
                loaded = try await persistence.loadMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
            }
            guard let draft = loaded else { return nil }
            let attachments = await MediaDraftProcessor.restoredDraftAttachments(
                from: draft.mediaAttachments
            )
            guard !resetPausedKeys.contains(key), !resetKeys.contains(key) else { return nil }
            return Self.normalizedSnapshot(ConversationDraftSnapshot(
                canonicalText: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex,
                mediaAttachments: attachments
            ))
        } catch is CancellationError {
            return nil
        } catch {
            loadErrorKeys.insert(key)
            if let state = persistence as? AppState {
                state.present(UserFacingError.toast(title: L10n.string("Couldn't load draft"), error: error))
            }
            Self.logger.error("Failed to hydrate encrypted composer draft")
            return nil
        }
    }

    func setDraft(
        _ snapshot: ConversationDraftSnapshot,
        accountRef: String,
        groupIdHex: String
    ) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard !resetPausedKeys.contains(key) else { return }
        resetKeys.remove(key)
        let operation = Self.normalizedSnapshot(snapshot).map(PendingOperation.save) ?? .delete
        if case .delete = operation, suppressEmptyAfterSendKeys.contains(key) { return }
        suppressEmptyAfterSendKeys.remove(key)
        if sendingKeys.contains(key) {
            if case .delete = operation, !editedWhileSending.contains(key) { return }
            editedWhileSending.insert(key)
        }
        if pendingWrites[key]?.operation == operation {
            return
        }
        if pendingWrites[key] == nil {
            switch operation {
            case .save(let snapshot) where Self.summary(summaries[key], matches: snapshot):
                return
            case .delete where summaries[key] == nil:
                return
            default:
                break
            }
        }

        nextRevision &+= 1
        pendingWrites[key] = PendingWrite(revision: nextRevision, operation: operation)
        switch operation {
        case .save(let snapshot):
            summaries[key] = Self.optimisticSummary(
                for: snapshot,
                groupIdHex: groupIdHex,
                existing: summaries[key]
            )
        case .delete:
            summaries[key] = nil
        }
        generation &+= 1
        scheduleSave(for: key)
    }

    func pauseForGroupReset(accountRef: String, groupIdHex: String) async {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        resetPausedKeys.insert(key)
        saveTasks.removeValue(forKey: key)?.cancel()
        if activeWrites[key, default: 0] > 0 {
            await withCheckedContinuation { resetWaiters[key, default: []].append($0) }
        }
    }

    func finishGroupReset(accountRef: String, groupIdHex: String, succeeded: Bool) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        resetPausedKeys.remove(key)
        if succeeded {
            resetKeys.insert(key)
            selections[key] = nil
            suppressEmptyAfterSendKeys.remove(key)
            conflictedKeys.remove(key)
            pendingWrites[key] = nil
            summaries[key] = nil
            generation &+= 1
        } else if pendingWrites[key] != nil {
            scheduleSave(for: key)
        }
    }

    func removeDraft(accountRef: String, groupIdHex: String) {
        guard !resetKeys.contains(ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)) else { return }
        setDraft(
            ConversationDraftSnapshot(
                canonicalText: "",
                replyToMessageIdHex: nil,
                mediaAttachments: []
            ),
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    /// Clears projections after a destructive account wipe. Marmot has already
    /// deleted the account database, so no per-draft binding calls are possible
    /// or necessary here.
    func removeDrafts(accountRef: String) {
        let keys = Set(summaries.keys.filter { $0.accountRef == accountRef })
            .union(pendingWrites.keys.filter { $0.accountRef == accountRef })
            .union(selections.keys.filter { $0.accountRef == accountRef })
        guard !keys.isEmpty else { return }
        for key in keys {
            saveTasks.removeValue(forKey: key)?.cancel()
            pendingWrites[key] = nil
            summaries[key] = nil
            selections[key] = nil
            suppressEmptyAfterSendKeys.remove(key)
            conflictedKeys.remove(key)
            sendingKeys.remove(key)
            editedWhileSending.remove(key)
        }
        loadedAccounts.remove(accountRef)
        generation &+= 1
    }

    func flush() async {
        let keys = Array(pendingWrites.keys)
        for key in keys {
            await flush(key: key, using: nil)
        }
    }

    /// Lifecycle path used while AppState holds a foreground-runtime mutation
    /// lease. The lease keeps the runtime and SQLCipher database alive until all
    /// pending draft writes finish.
    func flush(using client: MarmotClient) async {
        let keys = Array(pendingWrites.keys)
        for key in keys {
            await flush(key: key, using: client)
        }
    }

    private func applyLoadedSummaries(
        _ loaded: [MessageDraftSummaryFfi],
        accountRef: String
    ) {
        let pendingKeys = Set(pendingWrites.keys)
        summaries = summaries.filter {
            $0.key.accountRef != accountRef || pendingKeys.contains($0.key)
        }
        for summary in loaded {
            let key = ConversationDraftKey(
                accountRef: accountRef,
                groupIdHex: summary.groupIdHex
            )
            if pendingWrites[key] == nil, !resetPausedKeys.contains(key), !resetKeys.contains(key) {
                summaries[key] = summary
            }
        }
        generation &+= 1
    }

    private func scheduleSave(for key: ConversationDraftKey) {
        saveTasks.removeValue(forKey: key)?.cancel()
        saveTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush(key: key, using: nil)
        }
    }

    private func flush(key: ConversationDraftKey, using client: MarmotClient?) async {
        saveTasks.removeValue(forKey: key)?.cancel()
        guard !sendingKeys.contains(key), !conflictedKeys.contains(key) else { return }
        if activeWrites[key, default: 0] > 0 {
            await withCheckedContinuation { resetWaiters[key, default: []].append($0) }
        }
        guard !resetPausedKeys.contains(key), !sendingKeys.contains(key),
              !conflictedKeys.contains(key), let pending = pendingWrites[key] else { return }
        activeWrites[key, default: 0] += 1
        defer {
            activeWrites[key, default: 0] -= 1
            if activeWrites[key] == 0 {
                activeWrites[key] = nil
                resetWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
            }
        }

        do {
            let state = persistence as? AppState
            let lease = try client == nil ? state?.runtimeLifecycle.beginForegroundRuntimeMutation() : nil
            defer { if let lease { state?.runtimeLifecycle.endForegroundRuntimeMutation(lease) } }
            if let liveClient = client ?? lease?.client {
                let selected: SelectedMessageDraftFfi
                if let cached = selections[key] { selected = cached }
                else { selected = try await liveClient.selectedMessageDraft(accountRef: key.accountRef, groupIdHex: key.groupIdHex) }
                let saved: SelectedMessageDraftFfi
                switch pending.operation {
                case .save(let snapshot):
                    saved = try await liveClient.saveMessageDraftIfRevision(accountRef: key.accountRef,
                        revision: selected.revision, snapshot: snapshot)
                case .delete:
                    saved = try await liveClient.clearMessageDraftIfRevision(accountRef: key.accountRef, revision: selected.revision)
                }
                selections[key] = saved
                if pendingWrites[key]?.revision == pending.revision {
                    pendingWrites[key] = nil
                    summaries[key] = Self.summary(for: saved)
                    generation &+= 1
                }
                return
            }
            let saved: MessageDraftFfi?
            switch pending.operation {
            case .save(let snapshot):
                if let client {
                    saved = try await client.saveMessageDraft(
                        accountRef: key.accountRef,
                        groupIdHex: key.groupIdHex,
                        content: snapshot.canonicalText,
                        replyToMessageIdHex: snapshot.replyToMessageIdHex,
                        mediaAttachments: snapshot.mediaAttachments.map(\.messageDraftAttachment)
                    )
                } else {
                    guard let persistence else { return }
                    saved = try await persistence.persistMessageDraft(
                        accountRef: key.accountRef,
                        groupIdHex: key.groupIdHex,
                        snapshot: snapshot
                    )
                }
            case .delete:
                if let client {
                    try await client.deleteMessageDraft(
                        accountRef: key.accountRef,
                        groupIdHex: key.groupIdHex
                    )
                } else {
                    guard let persistence else { return }
                    try await persistence.deletePersistedMessageDraft(
                        accountRef: key.accountRef,
                        groupIdHex: key.groupIdHex
                    )
                }
                saved = nil
            }

            guard pendingWrites[key]?.revision == pending.revision else { return }
            pendingWrites[key] = nil
            summaries[key] = saved.map(MessageDraftSummaryFfi.init)
            generation &+= 1
        } catch MarmotKitError.MessageDraftRevisionConflict {
            conflictedKeys.insert(key)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Failed to persist encrypted composer draft")
        }
    }

    private func migrateLegacyDrafts(accountRef: String) async {
        guard let persistence else { return }
        let entries = await legacyFile.entries(accountRef: accountRef)
        for entry in entries {
            let key = entry.key
            if pendingWrites[key] != nil {
                await legacyFile.remove(key: key)
                continue
            }
            if let summary = summaries[key],
               Self.updatedAtMilliseconds(for: entry) <= summary.updatedAtMs {
                await legacyFile.remove(key: key)
                continue
            }
            guard let text = Self.normalizedLegacyText(entry.text) else {
                await legacyFile.remove(key: key)
                continue
            }

            let selectedMentions = entry.mentions.map {
                ComposerMentionSelection(
                    utf16Location: $0.utf16Location,
                    utf16Length: $0.utf16Length,
                    displayName: $0.displayName,
                    npub: $0.npub
                )
            }
            let canonicalText = ComposerMentionCanonicalizer.canonicalize(
                text,
                candidates: [],
                selectedMentions: selectedMentions,
                rosterResolution: .unresolved
            )
            let snapshot = ConversationDraftSnapshot(
                canonicalText: canonicalText,
                replyToMessageIdHex: nil,
                mediaAttachments: []
            )
            do {
                if let state = persistence as? AppState {
                    let lease = try state.runtimeLifecycle.beginForegroundRuntimeMutation()
                    defer { state.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
                    let selected = try await lease.client.selectedMessageDraft(accountRef: accountRef, groupIdHex: key.groupIdHex)
                    // A durable SDK draft always wins over legacy device storage.
                    if selected.draft == nil {
                        let saved = try await lease.client.saveMessageDraftIfRevision(accountRef: accountRef,
                            revision: selected.revision, snapshot: snapshot)
                        selections[key] = saved
                        if let hydrated = try await lease.client.hydrateSelectedDraft(accountRef: accountRef, selected: saved) {
                            summaries[key] = MessageDraftSummaryFfi(hydrated)
                        }
                    }
                } else {
                    let saved = try await persistence.persistMessageDraft(accountRef: accountRef,
                        groupIdHex: key.groupIdHex, snapshot: snapshot)
                    summaries[key] = MessageDraftSummaryFfi(saved)
                }
                generation &+= 1
                await legacyFile.remove(key: key)
            } catch {
                Self.logger.error("Failed to migrate legacy composer draft")
            }
        }
    }

    private static func summary(for selection: SelectedMessageDraftFfi) -> MessageDraftSummaryFfi? {
        selection.draft.map { draft in
            MessageDraftSummaryFfi(groupIdHex: draft.groupIdHex, content: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex,
                mediaAttachments: draft.mediaAttachments.map { MessageDraftAttachmentSummaryFfi(
                    id: $0.id, fileName: $0.fileName, mediaType: $0.mediaType, plaintextSize: $0.plaintextSize) },
                createdAtMs: draft.createdAtMs, updatedAtMs: draft.updatedAtMs)
        }
    }

    private nonisolated static func normalizedSnapshot(
        _ snapshot: ConversationDraftSnapshot
    ) -> ConversationDraftSnapshot? {
        let content = String(snapshot.canonicalText.prefix(maximumCanonicalTextLength))
        let replyToMessageIdHex = Hex.normalized32Bytes(snapshot.replyToMessageIdHex)
        var attachmentIDs = Set<UUID>()
        let attachments = snapshot.mediaAttachments
            .prefix(MediaDraftProcessor.maxAttachmentCount)
            .filter { attachment in
                let maxBytes = attachment.kind == .image
                    ? MediaDraftProcessor.maxImageAttachmentBytes
                    : MediaDraftProcessor.maxAttachmentBytes
                return attachment.data.count <= maxBytes
                    && attachmentIDs.insert(attachment.id).inserted
                    && attachment.durationSeconds?.isFinite != false
                    && attachment.waveformSamples.allSatisfy(\.isFinite)
            }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || replyToMessageIdHex != nil
                || !attachments.isEmpty
        else { return nil }
        return ConversationDraftSnapshot(
            canonicalText: content,
            replyToMessageIdHex: replyToMessageIdHex,
            mediaAttachments: Array(attachments)
        )
    }

    private nonisolated static func normalizedLegacyText(_ text: String) -> String? {
        let capped = String(text.prefix(ContentSanitizer.maxMessageLength))
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capped
    }

    private nonisolated static func summary(
        _ summary: MessageDraftSummaryFfi?,
        matches snapshot: ConversationDraftSnapshot
    ) -> Bool {
        guard let summary,
              summary.content == snapshot.canonicalText,
              summary.replyToMessageIdHex == snapshot.replyToMessageIdHex,
              summary.mediaAttachments.count == snapshot.mediaAttachments.count
        else { return false }
        return zip(summary.mediaAttachments, snapshot.mediaAttachments).allSatisfy {
            stored, local in
            stored.id == local.id.uuidString
                && stored.fileName == local.fileName
                && stored.mediaType == local.mediaType
                && stored.plaintextSize == UInt64(local.data.count)
        }
    }

    private nonisolated static func optimisticSummary(
        for snapshot: ConversationDraftSnapshot,
        groupIdHex: String,
        existing: MessageDraftSummaryFfi?
    ) -> MessageDraftSummaryFfi {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return MessageDraftSummaryFfi(
            groupIdHex: groupIdHex,
            content: snapshot.canonicalText,
            replyToMessageIdHex: snapshot.replyToMessageIdHex,
            mediaAttachments: snapshot.mediaAttachments.map {
                MessageDraftAttachmentSummaryFfi(
                    id: $0.id.uuidString,
                    fileName: $0.fileName,
                    mediaType: $0.mediaType,
                    plaintextSize: UInt64($0.data.count)
                )
            },
            createdAtMs: existing?.createdAtMs ?? now,
            updatedAtMs: now
        )
    }

    private nonisolated static func updatedAtMilliseconds(
        for entry: LegacyConversationDraftEntry
    ) -> Int64 {
        let (milliseconds, overflow) = entry.updatedAt.multipliedReportingOverflow(by: 1_000)
        guard !overflow, milliseconds <= UInt64(Int64.max) else { return Int64.max }
        return Int64(milliseconds)
    }

    private nonisolated static func defaultLegacyFileURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("conversation-drafts.json", isDirectory: false)
    }
}

private extension MessageDraftSummaryFfi {
    init(_ draft: MessageDraftFfi) {
        self.init(
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

extension AppState: ConversationDraftPersistence {
    func loadMessageDraftSummaries(accountRef: String) async throws
        -> [MessageDraftSummaryFfi]
    {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await lease.client.messageDrafts(accountRef: accountRef)
    }

    func loadMessageDraft(accountRef: String, groupIdHex: String) async throws
        -> MessageDraftFfi?
    {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await lease.client.messageDraft(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    func persistMessageDraft(
        accountRef: String,
        groupIdHex: String,
        snapshot: ConversationDraftSnapshot
    ) async throws -> MessageDraftFfi {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        return try await lease.client.saveMessageDraft(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            content: snapshot.canonicalText,
            replyToMessageIdHex: snapshot.replyToMessageIdHex,
            mediaAttachments: snapshot.mediaAttachments.map(\.messageDraftAttachment)
        )
    }

    func deletePersistedMessageDraft(accountRef: String, groupIdHex: String) async throws {
        let lease = try runtimeLifecycle.beginForegroundRuntimeMutation()
        defer { runtimeLifecycle.endForegroundRuntimeMutation(lease) }
        try await lease.client.deleteMessageDraft(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }
}

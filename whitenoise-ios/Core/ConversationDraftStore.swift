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
        if let pending = pendingWrites[key] {
            switch pending.operation {
            case .save(let snapshot):
                return snapshot
            case .delete:
                return nil
            }
        }
        guard let persistence else { return nil }
        do {
            guard let draft = try await persistence.loadMessageDraft(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            ) else { return nil }
            let attachments = await MediaDraftProcessor.restoredDraftAttachments(
                from: draft.mediaAttachments
            )
            return Self.normalizedSnapshot(ConversationDraftSnapshot(
                canonicalText: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex,
                mediaAttachments: attachments
            ))
        } catch is CancellationError {
            return nil
        } catch {
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
        let operation = Self.normalizedSnapshot(snapshot).map(PendingOperation.save) ?? .delete
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

    func removeDraft(accountRef: String, groupIdHex: String) {
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
        guard !keys.isEmpty else { return }
        for key in keys {
            saveTasks.removeValue(forKey: key)?.cancel()
            pendingWrites[key] = nil
            summaries[key] = nil
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
            if pendingWrites[key] == nil {
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
        guard let pending = pendingWrites[key] else { return }

        do {
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
                let saved = try await persistence.persistMessageDraft(
                    accountRef: accountRef,
                    groupIdHex: key.groupIdHex,
                    snapshot: snapshot
                )
                summaries[key] = MessageDraftSummaryFfi(saved)
                generation &+= 1
                await legacyFile.remove(key: key)
            } catch {
                Self.logger.error("Failed to migrate legacy composer draft")
            }
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

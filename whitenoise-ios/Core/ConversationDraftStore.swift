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

    /// Without the attachments only a file-backed draft can hold, for the
    /// whole-draft saves that carry every attachment's bytes.
    var withInlineAttachments: ConversationDraftSnapshot {
        ConversationDraftSnapshot(canonicalText: canonicalText, replyToMessageIdHex: replyToMessageIdHex,
                                  mediaAttachments: mediaAttachments.filter(MediaDraftProcessor.persistsInDraft))
    }
}

/// Outcome of hydrating one conversation's persisted composer draft.
/// `runtimeUnavailable` is transient (e.g. a notification tap that opens the
/// conversation while the runtime is still resuming) and is retried silently
/// once the runtime is ready.
nonisolated enum ConversationDraftLoadResult: Equatable {
    case loaded(ConversationDraftSnapshot?)
    case runtimeUnavailable
    case failed
    case cancelled

    /// Only an authoritative read may mark the composer hydrated; until then an
    /// untouched composer must not be persisted over the saved draft.
    var hydratesComposer: Bool {
        if case .loaded = self { return true }
        return false
    }

    static func classify(_ error: Error) -> ConversationDraftLoadResult {
        if error is CancellationError { return .cancelled }
        if case ForegroundRuntimeMutationError.runtimeUnavailable = error { return .runtimeUnavailable }
        if let error = error as? MarmotKitError, error.isTransientStartupReadinessFailure {
            return .runtimeUnavailable
        }
        return .failed
    }
}

nonisolated enum ConversationDraftHydrationGate {
    /// Before the saved draft is hydrated, only a real edit may be persisted.
    /// An empty composer (e.g. one restored when a message edit ends) is not an
    /// edit, and writing it would delete the draft that has not loaded yet.
    static func countsAsComposerChange(
        isHydrated: Bool,
        alreadyChanged: Bool,
        composerIsEmpty: Bool
    ) -> Bool {
        isHydrated || alreadyChanged || !composerIsEmpty
    }

    /// Whether a composer's writes keep the saved draft's files: until it has
    /// received the draft, unless the draft couldn't be read (then nothing
    /// could ever show or remove them, and every send would fail on them).
    static func keepsSavedFiles(isHydrated: Bool, hydrationFailed: Bool) -> Bool {
        !isHydrated && !hydrationFailed
    }

    /// A composer edited while its draft loaded keeps its own content and
    /// gains the saved attachments it doesn't have, saved ones first.
    static func attachments(
        composer: [MediaDraftAttachment],
        loaded: [MediaDraftAttachment]
    ) -> [MediaDraftAttachment] {
        let own = Set(composer.map(\.id))
        return Array((loaded.filter { !own.contains($0.id) } + composer).prefix(MediaDraftProcessor.maxAttachmentCount))
    }
}

/// Chat-list presentation of a revision-checked send between capturing its
/// draft revision and MDK settling it (MDK 0.13 pending-send draft handoff).
/// It only correlates the row's opaque `draftVersion` with `revision`; it never
/// authorizes clearing a draft. MDK consumes exactly that revision on durable
/// acceptance, and nothing else deletes the draft on the handoff's strength.
nonisolated struct PendingDraftSendHandoff {
    let revision: MessageDraftRevisionFfi
    /// What was submitted, rendered as the pending outgoing preview.
    let submitted: MessageDraftSummaryFfi

    /// Whether the handoff outlives a settled send. It stays only when the send
    /// was accepted and MDK then selects no draft, so a chat-list snapshot that
    /// still shows the consumed revision cannot flash it back as a draft. A
    /// rejected or unconfirmed send, or one that left a draft selected, restores
    /// MDK's row as is.
    static func retainsAfterSend(accepted: Bool, selectedHasDraft: Bool?) -> Bool {
        accepted && selectedHasDraft == false
    }
}

/// Bounded retry for a draft load that reported `runtimeUnavailable` after the
/// host already considered the runtime ready (e.g. a transient startup-readiness
/// error). The final attempt surfaces such failures instead of staying silent.
/// Readiness changes restart the load through the view's task token.
@MainActor
enum ConversationDraftLoadRetry {
    nonisolated static let delays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    static func run(
        delays: [Duration] = delays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        attempt: (_ isFinalAttempt: Bool) async -> ConversationDraftLoadResult?
    ) async -> ConversationDraftLoadResult? {
        var result = await attempt(delays.isEmpty)
        for (index, delay) in delays.enumerated() {
            guard result == .runtimeUnavailable else { return result }
            do { try await sleep(delay) } catch { return .cancelled }
            result = await attempt(index == delays.count - 1)
        }
        return result
    }
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

        /// Attachments compare without their bytes: a file-backed one can be
        /// hundreds of MiB, and its id never names other bytes.
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.delete, .delete):
                return true
            case (.save(let lhs), .save(let rhs)):
                func identity(_ snapshot: ConversationDraftSnapshot) -> [String] {
                    snapshot.mediaAttachments.map {
                        "\($0.id)|\($0.fileName)|\($0.mediaType)|\($0.data.count)|\($0.dim ?? "")|\($0.thumbhash ?? "")"
                    }
                }
                return lhs.canonicalText == rhs.canonicalText && lhs.replyToMessageIdHex == rhs.replyToMessageIdHex
                    && identity(lhs) == identity(rhs)
            default:
                return false
            }
        }
    }

    private struct PendingWrite: Equatable {
        let revision: UInt64
        let operation: PendingOperation
        /// Written by a composer that hasn't received the saved draft: the
        /// write keeps every file MDK holds that it doesn't name, since
        /// leaving one out would have MDK delete it.
        let keepsSavedFiles: Bool
    }

    /// A composer edit recorded while writes wait, applied afterwards.
    private struct RecordedEdit {
        let snapshot: ConversationDraftSnapshot
        let keepsSavedFiles: Bool
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
    @ObservationIgnored private var pendingSendHandoffs: [ConversationDraftKey: PendingDraftSendHandoff] = [:]
    /// Large attachments MDK is copying into the draft as files, by chat and id.
    @ObservationIgnored private var stagingControls: [ConversationDraftKey: [String: MediaFileTransferControlFfi]] = [:]
    /// Advances when MDK finishes holding a large attachment as a file, so the
    /// composer can start its pre-upload.
    private(set) var fileBackedGeneration = 0
    /// Draft sends tapped but not yet claimed, by chat. Composer edits are
    /// only recorded meanwhile: a save of the next message would drop the
    /// tapped one's staged files, which MDK then deletes.
    @ObservationIgnored private var unclaimedSends: [ConversationDraftKey: Int] = [:]
    /// The composer's latest content since the last Send tap, applied once
    /// every tapped send is claimed.
    @ObservationIgnored private var typedWhileQueued: [ConversationDraftKey: RecordedEdit?] = [:]
    /// Chats whose Send is writing and claiming its submission.
    @ObservationIgnored private var claimingKeys: Set<ConversationDraftKey> = []
    /// A composer's read of the saved draft, by chat. It holds the draft's
    /// write slot, so no write changes the revision it reads, and the
    /// runtime's suspension cancels it rather than waiting.
    @ObservationIgnored private var hydrationReads: [ConversationDraftKey: Task<(SelectedMessageDraftFfi, MessageDraftFfi?), Error>] = [:]
    /// Writes the host copy of a large attachment that MDK then copies into the
    /// draft. Runs outside the draft's write slot.
    @ObservationIgnored private let prepareStagingSource: @Sendable (MediaDraftAttachment) async throws -> MediaUploadSourceFiles
    /// Reads a selected draft's attachments for a composer (chunked for files).
    @ObservationIgnored private let readSelectedDraft: @MainActor (MarmotClient, String, SelectedMessageDraftFfi) async throws -> MessageDraftFfi?
    /// Advances whenever a pending-send handoff starts or ends, so the chat
    /// list can re-project its rows.
    private(set) var pendingSendHandoffGeneration = 0
    private(set) var loadErrorKeys: Set<ConversationDraftKey> = []
    private(set) var conflictedKeys: Set<ConversationDraftKey> = []
    /// Custom emoji sends (`sendTaggedMedia`, no draft revision or client
    /// token) in flight, by chat. Owned here so the claim outlives the
    /// conversation screen: a reopened composer sees it and cannot send the
    /// same text again.
    private(set) var unrevisionedSends: [ConversationDraftKey: UnrevisionedSend] = [:]
    /// The last accepted unrevisioned submission per chat, until the composer
    /// moves on. The composer on screen clears itself when it still shows this
    /// submission, and saving the same text again is ignored.
    private(set) var acceptedUnrevisionedSends: [ConversationDraftKey: UnrevisionedSend] = [:]

    /// The attachments MDK holds as files in this chat's draft.
    func fileBackedAttachmentIDs(accountRef: String, groupIdHex: String) -> Set<String> {
        MessageDraftAttachmentInputs.fileBackedIDs(
            in: selections[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
        )
    }

    /// Whether the draft holds every attachment, so Send can go through its revision.
    func sendsThroughDraft(_ attachments: [MediaDraftAttachment], accountRef: String, groupIdHex: String) -> Bool {
        MediaDraftProcessor.sendsThroughDraft(
            attachments, fileBackedIDs: fileBackedAttachmentIDs(accountRef: accountRef, groupIdHex: groupIdHex)
        )
    }

    /// Copies each large attachment of the draft into it as a file, so it
    /// survives leaving the chat and sends through the draft's revision.
    /// Cancels the copy of one the draft no longer holds. Driven by draft
    /// edits, never by a composer that hasn't loaded the draft yet. A copy
    /// that fails leaves the attachment out of the draft, sent as before.
    private func stageLargeAttachments(_ attachments: [MediaDraftAttachment], key: ConversationDraftKey) {
        let wanted = attachments.filter(MessageDraftAttachmentInputs.needsStaging)
        let wantedIDs = Set(wanted.map(\.id.uuidString))
        var controls = stagingControls[key] ?? [:]
        for (id, control) in controls where !wantedIDs.contains(id) {
            control.cancel()
            controls[id] = nil
        }
        let held = MessageDraftAttachmentInputs.fileBackedIDs(in: selections[key])
        for attachment in wanted {
            let id = attachment.id.uuidString
            // A cancelled copy may still be returning; start a new one.
            guard controls[id]?.isCancelled() ?? true, !held.contains(id) else { continue }
            let control = MediaFileTransferControlFfi()
            controls[id] = control
            Task { [weak self] in await self?.stage(attachment, key: key, control: control) }
        }
        stagingControls[key] = controls.isEmpty ? nil : controls
    }

    private func stage(_ attachment: MediaDraftAttachment, key: ConversationDraftKey,
                       control: MediaFileTransferControlFfi) async {
        let id = attachment.id.uuidString
        defer {
            if stagingControls[key]?[id] === control {
                stagingControls[key]?[id] = nil
                if stagingControls[key]?.isEmpty == true { stagingControls[key] = nil }
            }
        }
        guard let state = persistence as? AppState else { return }
        // The host copy MDK reads from is written before taking the draft's
        // write slot, so no save waits for it. A copy cancelled meanwhile
        // (the runtime suspending) stops here.
        let sources: MediaUploadSourceFiles
        do { sources = try await prepareStagingSource(attachment) } catch {
            Self.logger.error("Failed to keep a large attachment in the composer draft")
            return
        }
        await copyIntoDraft(attachment, from: sources, key: key, control: control, state: state)
        await sources.remove()
    }

    private func copyIntoDraft(_ attachment: MediaDraftAttachment, from sources: MediaUploadSourceFiles,
                               key: ConversationDraftKey, control: MediaFileTransferControlFfi, state: AppState) async {
        // One write at a time per draft: a save waits for the copy and then
        // uses the revision it returns, keeping the file by id.
        while !control.isCancelled(), activeWrites[key, default: 0] > 0 {
            await withCheckedContinuation { resetWaiters[key, default: []].append($0) }
        }
        guard !control.isCancelled(), !resetPausedKeys.contains(key), !sendingKeys.contains(key),
              unclaimedSends[key] == nil, !conflictedKeys.contains(key) else { return }
        activeWrites[key, default: 0] += 1
        defer {
            activeWrites[key, default: 0] -= 1
            if activeWrites[key] == 0 {
                activeWrites[key] = nil
                resetWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
            }
        }
        do {
            // No runtime lease: a suspension that closes the runtime fails the
            // copy, and the attachment is sent as before.
            let client = try state.currentMarmotClient()
            let selected: SelectedMessageDraftFfi
            if let cached = selections[key] { selected = cached }
            else { selected = try await client.selectedMessageDraft(accountRef: key.accountRef, groupIdHex: key.groupIdHex) }
            let staged = try await client.stageMessageDraftAttachment(
                accountRef: key.accountRef, revision: selected.revision, attachment: attachment,
                sourcePath: sources.urls[0].path, control: control
            )
            selections[key] = staged
            fileBackedGeneration &+= 1
            if pendingWrites[key] == nil {
                summaries[key] = Self.summary(for: staged)
                generation &+= 1
            }
            // A write that waited saves next, on the new revision.
        } catch MarmotKitError.MessageDraftRevisionConflict {
            // The draft was cleared or sent during the copy, which discards it.
            return
        } catch {
            if !control.isCancelled() { Self.logger.error("Failed to keep a large attachment in the composer draft") }
        }
    }

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
    /// claim by revision. Until `prepareSend` claims it, whatever the user types
    /// is only recorded (`setDraft`); it is applied once every tapped send is
    /// claimed. Every call is followed by one `prepareSend`.
    func beginQueuedSend(accountRef: String, groupIdHex: String) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        suppressEmptyAfterSendKeys.insert(key)
        unclaimedSends[key, default: 0] += 1
        typedWhileQueued[key] = .some(nil)
    }

    /// `keepsSavedFiles`: the composer hasn't received the saved draft (see
    /// `setDraft`). The claim then keeps its files, and fails on them.
    func prepareSend(_ snapshot: ConversationDraftSnapshot, accountRef: String, groupIdHex: String,
                     keepsSavedFiles: Bool = false) async throws -> MessageDraftRevisionFfi {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        if unclaimedSends[key] == nil {
            unclaimedSends[key] = 1
            typedWhileQueued[key] = .some(nil)
        }
        guard !sendingKeys.contains(key), !claimingKeys.contains(key), !conflictedKeys.contains(key) else {
            endClaim(key)
            throw MarmotKitError.MessageDraftRevisionConflict
        }
        claimingKeys.insert(key)
        // Runs after a successful claim has marked the chat sending, so what
        // was typed meanwhile is saved by `finishSend`.
        defer {
            claimingKeys.remove(key)
            endClaim(key)
        }
        // Wait out a running write first (a large attachment's copy can take a while).
        while activeWrites[key, default: 0] > 0 {
            await withCheckedContinuation { resetWaiters[key, default: []].append($0) }
        }
        guard !sendingKeys.contains(key), !conflictedKeys.contains(key) else {
            throw MarmotKitError.MessageDraftRevisionConflict
        }
        applyDraft(snapshot, key: key, keepsSavedFiles: keepsSavedFiles)
        await flush(key: key, using: nil)
        // The revision must hold exactly the tapped attachments: not one MDK no
        // longer holds (left out of the write), and not one the composer never
        // received (kept by the write, but not part of what was tapped).
        guard pendingWrites[key] == nil, let selection = selections[key],
              Self.holdsExactlyAttachments(of: snapshot, in: selection) else {
            throw MarmotKitError.MessageDraftRevisionConflict
        }
        sendingKeys.insert(key)
        suppressEmptyAfterSendKeys.insert(key)
        activeWrites[key, default: 0] += 1
        editedWhileSending.remove(key)
        setPendingSendHandoff(Self.summary(for: selection).map {
            PendingDraftSendHandoff(revision: selection.revision, submitted: $0)
        }, for: key)
        return selection.revision
    }

    /// Whether the draft `selection` holds the attachments of `snapshot` and no others.
    nonisolated static func holdsExactlyAttachments(of snapshot: ConversationDraftSnapshot, in selection: SelectedMessageDraftFfi) -> Bool {
        guard let draft = selection.draft else { return false }
        return Set(draft.mediaAttachments.map(\.id)) == Set(snapshot.mediaAttachments.map(\.id.uuidString))
    }

    /// Ends every copy into a draft and every composer's read of one, so the
    /// writes waiting behind them can run before the runtime suspends. A
    /// cancelled copy's attachment is left out of saves and copied again on
    /// the next edit, or sent without a revision; a cancelled read is retried
    /// when the runtime is back.
    private func cancelDraftTransfers() {
        for controls in stagingControls.values {
            for control in controls.values { control.cancel() }
        }
        for read in hydrationReads.values { read.cancel() }
    }

    /// Ends one tapped send's hold. Once none is left unclaimed, applies what
    /// the composer was given after the last tap. A cleared composer changes
    /// nothing: the submission's draft stays until it sends.
    private func endClaim(_ key: ConversationDraftKey) {
        let remaining = unclaimedSends[key, default: 1] - 1
        guard remaining <= 0 else {
            unclaimedSends[key] = remaining
            return
        }
        unclaimedSends[key] = nil
        if case .some(.some(let typed)) = typedWhileQueued.removeValue(forKey: key) {
            applyDraft(typed.snapshot, key: key, keepsSavedFiles: typed.keepsSavedFiles)
        }
    }

    func finishSend(accountRef: String, groupIdHex: String, accepted: Bool) async {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        var selectedHasDraft: Bool?
        if accepted, let state = persistence as? AppState,
           let client = try? state.currentMarmotClient(),
           let selected = try? await client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex) {
            selectedHasDraft = selected.draft != nil
            selections[key] = selected
            if pendingWrites[key] == nil {
                summaries[key] = Self.summary(for: selected)
                generation &+= 1
            }
        }
        if !PendingDraftSendHandoff.retainsAfterSend(accepted: accepted, selectedHasDraft: selectedHasDraft) {
            setPendingSendHandoff(nil, for: key)
        }
        if sendingKeys.remove(key) != nil {
            activeWrites[key, default: 0] -= 1
            if activeWrites[key] == 0 {
                activeWrites[key] = nil
                resetWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
            }
        }
        editedWhileSending.remove(key)
        if let pending = pendingWrites[key] {
            // Copies wait while a send runs; start those of the next message.
            if case .save(let next) = pending.operation { stageLargeAttachments(next.mediaAttachments, key: key) }
            scheduleSave(for: key)
        }
    }

    struct UnrevisionedSend: Equatable {
        let id: UUID
        let submitted: ConversationDraftSnapshot
    }

    /// Claims the chat for one unrevisioned send; nil while another is in
    /// flight for the same chat (from this screen or a reopened one).
    func beginUnrevisionedSend(_ submitted: ConversationDraftSnapshot, accountRef: String, groupIdHex: String) -> UUID? {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard unrevisionedSends[key] == nil, !sendingKeys.contains(key) else { return nil }
        let id = UUID()
        unrevisionedSends[key] = UnrevisionedSend(id: id, submitted: submitted)
        return id
    }

    func isUnrevisionedSendInFlight(accountRef: String, groupIdHex: String) -> Bool {
        unrevisionedSends[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)] != nil
    }

    func acceptedUnrevisionedSend(accountRef: String, groupIdHex: String) -> UnrevisionedSend? {
        acceptedUnrevisionedSends[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
    }

    /// Whether `snapshot` is the text MDK already accepted for this chat.
    func isAcceptedUnrevisionedSend(_ snapshot: ConversationDraftSnapshot, accountRef: String, groupIdHex: String) -> Bool {
        guard let accepted = acceptedUnrevisionedSend(accountRef: accountRef, groupIdHex: groupIdHex) else { return false }
        return Self.isSameSubmission(snapshot, accepted.submitted)
    }

    /// Releases the claim. On acceptance the saved draft is cleared (unless
    /// the person kept typing) before the claim is released, independently of
    /// any conversation screen, and the accepted submission is recorded for
    /// the composer on screen to reconcile.
    func finishUnrevisionedSend(_ id: UUID, accepted: Bool, accountRef: String, groupIdHex: String) async {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard let send = unrevisionedSends[key], send.id == id else { return }
        if accepted {
            await completeUnrevisionedSend(send.submitted, key: key)
            acceptedUnrevisionedSends[key] = send
        }
        if unrevisionedSends[key]?.id == id { unrevisionedSends[key] = nil }
    }

    /// The composer on screen applied (or declined) the accepted submission.
    func consumeAcceptedUnrevisionedSend(_ id: UUID, accountRef: String, groupIdHex: String) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        if acceptedUnrevisionedSends[key]?.id == id { acceptedUnrevisionedSends[key] = nil }
    }

    private func completeUnrevisionedSend(_ submitted: ConversationDraftSnapshot, key: ConversationDraftKey) async {
        guard !sendingKeys.contains(key), !conflictedKeys.contains(key),
              let current = await snapshot(accountRef: key.accountRef, groupIdHex: key.groupIdHex),
              Self.isSameSubmission(current, submitted)
        else { return }
        // A keystroke may have landed while the saved draft was read.
        if let pending = pendingWrites[key] {
            guard case .save(let latest) = pending.operation, Self.isSameSubmission(latest, submitted) else { return }
        }
        suppressEmptyAfterSendKeys.remove(key)
        removeDraft(accountRef: key.accountRef, groupIdHex: key.groupIdHex)
        await flush(key: key, using: nil)
    }

    nonisolated static func isSameSubmission(_ current: ConversationDraftSnapshot, _ submitted: ConversationDraftSnapshot) -> Bool {
        current.mediaAttachments.isEmpty
            && current.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
                == submitted.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
            && Hex.normalized32Bytes(current.replyToMessageIdHex) == Hex.normalized32Bytes(submitted.replyToMessageIdHex)
    }

    @ObservationIgnored private var nextRevision: UInt64 = 0

    init(
        persistence: ConversationDraftPersistence? = nil,
        legacyFileURL: URL? = nil,
        prepareStagingSource: @escaping @Sendable (MediaDraftAttachment) async throws -> MediaUploadSourceFiles = {
            try await MediaUploadSourceFiles.stage([$0])
        },
        readSelectedDraft: @escaping @MainActor (MarmotClient, String, SelectedMessageDraftFfi) async throws -> MessageDraftFfi? = {
            try await $0.hydrateSelectedDraft(accountRef: $1, selected: $2)
        }
    ) {
        self.persistence = persistence
        self.prepareStagingSource = prepareStagingSource
        self.readSelectedDraft = readSelectedDraft
        self.legacyFile = LegacyConversationDraftFile(
            url: legacyFileURL ?? Self.defaultLegacyFileURL()
        )
    }

    // Task cancellation needs no actor hop; avoid the older runtime's isolated-deinit crash.
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {
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

    func pendingSendHandoff(accountRef: String, groupIdHex: String) -> PendingDraftSendHandoff? {
        pendingSendHandoffs[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
    }

    private func setPendingSendHandoff(_ handoff: PendingDraftSendHandoff?, for key: ConversationDraftKey) {
        guard handoff != nil || pendingSendHandoffs[key] != nil else { return }
        pendingSendHandoffs[key] = handoff
        pendingSendHandoffGeneration &+= 1
    }

    func summary(accountRef: String, groupIdHex: String) -> MessageDraftSummaryFfi? {
        summaries[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
    }

    func snapshot(accountRef: String, groupIdHex: String) async -> ConversationDraftSnapshot? {
        guard case .loaded(let snapshot) = await loadSnapshot(accountRef: accountRef, groupIdHex: groupIdHex)
        else { return nil }
        return snapshot
    }

    /// `hydratingComposer`: the read restores a composer, which hasn't
    /// received the draft's files until `composerReceivedAttachments`.
    func loadSnapshot(
        accountRef: String,
        groupIdHex: String,
        surfacesTransientFailures: Bool = false,
        hydratingComposer: Bool = false
    ) async -> ConversationDraftLoadResult {
        await loadIfNeeded(accountRef: accountRef)
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        guard !resetPausedKeys.contains(key), !resetKeys.contains(key) else { return .loaded(nil) }
        // The saved draft is still the tapped message; a reopened composer
        // shows what was typed after it.
        if unclaimedSends[key] != nil { return .loaded(typedWhileQueued[key]??.snapshot) }
        // An edit from a composer that hasn't received the saved draft still
        // needs its files, so it doesn't stand in for the read.
        if let pending = pendingWrites[key], !(hydratingComposer && pending.keepsSavedFiles) {
            switch pending.operation {
            case .save(let snapshot):
                return .loaded(snapshot)
            case .delete:
                return .loaded(nil)
            }
        }
        guard let persistence else { return .loaded(nil) }
        loadErrorKeys.remove(key)
        do {
            let loaded: MessageDraftFfi?
            // Taken as the read ends, before a write waiting on it can run.
            var editBeforeRead: PendingWrite?
            if let state = persistence as? AppState {
                let client = try state.currentMarmotClient()
                if hydratingComposer {
                    loaded = try await readForComposer(key: key, client: client)
                    editBeforeRead = pendingWrites[key].flatMap { $0.keepsSavedFiles ? $0 : nil }
                } else {
                    let selected = try await client.selectedMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
                    selections[key] = selected
                    loaded = try await client.hydrateSelectedDraft(accountRef: accountRef, selected: selected)
                }
            } else {
                loaded = try await persistence.loadMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
            }
            let attachments = await MediaDraftProcessor.restoredDraftAttachments(
                from: loaded?.mediaAttachments ?? []
            )
            guard !resetPausedKeys.contains(key), !resetKeys.contains(key) else { return .loaded(nil) }
            // An edit made before the composer received the draft wins, with
            // the saved attachments it lacks.
            if let pending = editBeforeRead {
                let edited: ConversationDraftSnapshot? = switch pending.operation {
                case .save(let snapshot): snapshot
                case .delete: nil
                }
                return .loaded(Self.normalizedSnapshot(ConversationDraftSnapshot(
                    canonicalText: edited?.canonicalText ?? "",
                    replyToMessageIdHex: edited?.replyToMessageIdHex,
                    mediaAttachments: ConversationDraftHydrationGate.attachments(
                        composer: edited?.mediaAttachments ?? [], loaded: attachments)
                )))
            }
            guard let draft = loaded else { return .loaded(nil) }
            return .loaded(Self.normalizedSnapshot(ConversationDraftSnapshot(
                canonicalText: draft.content,
                replyToMessageIdHex: draft.replyToMessageIdHex,
                mediaAttachments: attachments
            )))
        } catch {
            let result = ConversationDraftLoadResult.classify(error)
            // A missing client is covered by the view's readiness gate; only a
            // startup-readiness error that outlives the retry budget surfaces.
            let surfacesTransient = surfacesTransientFailures && error is MarmotKitError
            guard result == .failed || (result == .runtimeUnavailable && surfacesTransient) else {
                if result == .runtimeUnavailable {
                    Self.logger.info("Deferred composer draft hydration until the runtime is ready")
                }
                return result
            }
            loadErrorKeys.insert(key)
            if let state = persistence as? AppState {
                state.present(UserFacingError.toast(title: L10n.string("Couldn't load draft"), error: error))
            }
            Self.logger.error("Failed to hydrate encrypted composer draft")
            return .failed
        }
    }

    /// Reads the saved draft for a composer while holding the draft's write
    /// slot: a write in between would change the revision its chunked reads
    /// are bound to. A send in flight already holds the slot and writes
    /// nothing, so the read doesn't wait for it.
    private func readForComposer(key: ConversationDraftKey, client: MarmotClient) async throws -> MessageDraftFfi? {
        while activeWrites[key, default: 0] > 0, !sendingKeys.contains(key) {
            await withCheckedContinuation { resetWaiters[key, default: []].append($0) }
        }
        try Task.checkCancellation()
        let holdsSlot = !sendingKeys.contains(key)
        if holdsSlot { activeWrites[key, default: 0] += 1 }
        defer {
            if holdsSlot {
                activeWrites[key, default: 0] -= 1
                if activeWrites[key] == 0 {
                    activeWrites[key] = nil
                    resetWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
                }
            }
        }
        let read = Task { @MainActor in
            let selected = try await client.selectedMessageDraft(accountRef: key.accountRef, groupIdHex: key.groupIdHex)
            return (selected, try await readSelectedDraft(client, key.accountRef, selected))
        }
        hydrationReads[key] = read
        defer { if hydrationReads[key] == read { hydrationReads[key] = nil } }
        let (selected, loaded) = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        selections[key] = selected
        return loaded
    }

    /// `keepsSavedFiles`: the composer hasn't received the saved draft yet
    /// (its read hasn't finished, or hasn't started), so the write keeps every
    /// file MDK holds that the snapshot doesn't name.
    func setDraft(
        _ snapshot: ConversationDraftSnapshot,
        accountRef: String,
        groupIdHex: String,
        keepsSavedFiles: Bool = false
    ) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        if unclaimedSends[key] != nil {
            typedWhileQueued[key] = .some(Self.normalizedSnapshot(snapshot) == nil
                ? nil : RecordedEdit(snapshot: snapshot, keepsSavedFiles: keepsSavedFiles))
            return
        }
        applyDraft(snapshot, key: key, keepsSavedFiles: keepsSavedFiles)
    }

    private func applyDraft(_ snapshot: ConversationDraftSnapshot, key: ConversationDraftKey, keepsSavedFiles: Bool = false) {
        let groupIdHex = key.groupIdHex
        guard !resetPausedKeys.contains(key) else { return }
        resetKeys.remove(key)
        let operation = Self.normalizedSnapshot(snapshot).map(PendingOperation.save) ?? .delete
        if let accepted = acceptedUnrevisionedSends[key] {
            // A composer still showing an accepted custom emoji message (for
            // example on disappear) must not save it back as a draft.
            if case .save(let latest) = operation, Self.isSameSubmission(latest, accepted.submitted) { return }
            acceptedUnrevisionedSends[key] = nil
        }
        if case .delete = operation, suppressEmptyAfterSendKeys.contains(key) { return }
        suppressEmptyAfterSendKeys.remove(key)
        if sendingKeys.contains(key) {
            if case .delete = operation, !editedWhileSending.contains(key) { return }
            editedWhileSending.insert(key)
        }
        if case .save(let saved) = operation {
            stageLargeAttachments(saved.mediaAttachments, key: key)
        } else {
            stageLargeAttachments([], key: key)
        }
        if let pending = pendingWrites[key], pending.operation == operation, pending.keepsSavedFiles == keepsSavedFiles {
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
        pendingWrites[key] = PendingWrite(revision: nextRevision, operation: operation, keepsSavedFiles: keepsSavedFiles)
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
            setPendingSendHandoff(nil, for: key)
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
            .union(pendingSendHandoffs.keys.filter { $0.accountRef == accountRef })
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
            acceptedUnrevisionedSends[key] = nil
            setPendingSendHandoff(nil, for: key)
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
        cancelDraftTransfers()
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
        // A large attachment's copy can start when the last write ends, so wait
        // until no write is running rather than for the current one.
        while activeWrites[key, default: 0] > 0 {
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
                let held = MessageDraftAttachmentInputs.fileBackedIDs(in: selected)
                let kept = pending.keepsSavedFiles ? held : []
                let saved: SelectedMessageDraftFfi
                switch pending.operation {
                case .save(let snapshot):
                    saved = try await liveClient.saveMessageDraftIfRevision(accountRef: key.accountRef,
                        revision: selected.revision, snapshot: snapshot, retainedIDs: held, keeping: kept)
                case .delete where !kept.isEmpty:
                    saved = try await liveClient.saveMessageDraftIfRevision(accountRef: key.accountRef,
                        revision: selected.revision,
                        snapshot: ConversationDraftSnapshot(canonicalText: "", replyToMessageIdHex: nil, mediaAttachments: []),
                        retainedIDs: held, keeping: kept)
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
                        mediaAttachments: snapshot.withInlineAttachments.mediaAttachments.map(\.messageDraftAttachment)
                    )
                } else {
                    guard let persistence else { return }
                    saved = try await persistence.persistMessageDraft(
                        accountRef: key.accountRef,
                        groupIdHex: key.groupIdHex,
                        snapshot: snapshot.withInlineAttachments
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
                // A large attachment stays: MDK may hold it as a file. Each save
                // leaves out one it doesn't hold yet (`MessageDraftAttachmentInputs`).
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
            mediaAttachments: snapshot.withInlineAttachments.mediaAttachments.map(\.messageDraftAttachment)
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

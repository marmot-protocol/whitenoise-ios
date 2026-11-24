import MarmotKit
import SwiftUI

struct TranscriptMediaTarget {
    let item: MessageMediaAttachment
    var id: String { item.id }
    var restored = false
    let scope: MessageBubble.MediaOpenScope
    var initialData: Data?
    var gifRowID: String? = nil
    var pending: MessageMediaGallery.PendingSelection?

    init(item: MessageMediaAttachment, scope: MessageBubble.MediaOpenScope, initialData: Data?,
         row: TimelineItem, media: [MessageMediaAttachment], gifRowID: String? = nil) {
        if case .message(let record, _) = row.kind { self.item = item.transcriptItem(in: record.messageIdHex) }
        else { self.item = item }
        self.scope = scope
        self.initialData = initialData
        self.gifRowID = gifRowID
        if case .message(let record, _) = row.kind, record.direction == "sent", item.reference == nil,
           let data = item.localData, let index = media.firstIndex(where: { $0.id == item.id }) {
            pending = .init(id: item.id, slot: .init(rowID: row.id, index: item.sourceHint?.slot ?? UInt32(index)), data: data)
        }
    }
}

/// Only the selected original slot is allowed to cross a runtime replacement.
struct TranscriptMediaBookmark: Equatable {
    let target: AttachmentLocalTargetFfi
    let reference: MediaAttachmentReferenceFfi

    init?(_ item: MessageMediaAttachment?) {
        guard let item, let target = item.localTarget, let reference = item.reference else { return nil }
        self.target = target
        self.reference = reference
    }

    func find(in model: ConversationViewModel) -> (row: TimelineItem, item: MessageMediaAttachment)? {
        let id = target.messageIdHex
        guard let record = model.conversationWindow?.messages.first(where: { $0.timeline.messageIdHex == id })?.timeline,
              !record.deleted, record.sourceMessageIdHex == target.sourceMessageIdHex,
              record.media.contains(.accepted(attachmentIndex: target.attachmentIndex, reference: reference)),
              let row = model.timeline.first(where: { model.protocolID(forDisplayID: $0.id) == id }),
              case .message(let displayed, _) = row.kind, displayed.messageIdHex == id, displayed.sender == record.sender,
              !model.timelineStore.isHidden(id), !model.isDeleted(id), !model.timelineStore.isBlockedAuthor(record.sender),
              let slot = model.mediaItems(for: row).first(where: { Self($0) == self }) else { return nil }
        return (row, slot.transcriptItem(in: id))
    }
}

@MainActor @Observable
final class TranscriptMediaSession: Identifiable {
    let id = UUID()
    let originalScope: MessageBubble.MediaOpenScope
    private(set) var target: TranscriptMediaTarget?
    @ObservationIgnored private var bookmark: TranscriptMediaBookmark?

    init(_ target: TranscriptMediaTarget) {
        self.target = target
        originalScope = target.scope
        bookmark = TranscriptMediaBookmark(target.item)
    }

    func didDisplay(_ item: MessageMediaAttachment?) {
        guard var opening = target else { return }
        bookmark = TranscriptMediaBookmark(item)
        if opening.restored, let item, opening.id != item.id {
            opening.initialData = nil
            opening.restored = false
            target = opening
        }
    }

    func suspend() { target = nil }

    func restore(in model: ConversationViewModel, appState: AppState) async throws {
        guard let bookmark, let scope = AttachmentHistoryPager.Scope(appState: appState, group: model.group.groupIdHex) else {
            throw AttachmentReadError.stale
        }
        func current() throws -> (TimelineItem, MessageMediaAttachment) {
            let now = MessageBubble.MediaOpenScope(model, appState: appState)
            _ = try scope.currentClient(in: appState)
            guard target == nil, appState.isAppSceneActive, originalScope.matchesConversation(now),
                  model.windowRuntime == .ready(now.generation),
                  let found = bookmark.find(in: model) else { throw AttachmentReadError.stale }
            return found
        }

        let (openingRow, openingItem) = try current()
        guard case .message(let message, _) = openingRow.kind else { throw AttachmentReadError.stale }
        let client = try scope.currentClient(in: appState)
        let baseline = try await scope.version(in: appState)
        // The live block-list subscription can still be attaching after resume.
        let blocked = try await Task.detached(priority: .userInitiated) {
            try client.marmot.getBlockedUsers(accountRef: scope.account)
        }.value
        guard !blocked.contains(where: { $0.publicKey.caseInsensitiveCompare(message.sender) == .orderedSame }) else {
            throw AttachmentReadError.stale
        }
        _ = try current()
        // The paused video needs only its retained slot until Play. A photo needs
        // verified pixels now, within the app's existing image-source budget.
        var data: Data?
        if !openingItem.isVideo {
            guard let bytes = try await client.attachmentData(accountRef: scope.account, groupID: scope.group,
                target: bookmark.target, previewByteLimit: MediaDraftProcessor.maxImageSourceBytes),
                await MediaPlaintextHash.matches(bytes, expectedSha256: bookmark.reference.plaintextSha256) else {
                throw AttachmentReadError.stale
            }
            data = bytes
        }
        _ = try current()
        // A retained asset requires a visible indexed slot. Blocking its author hides
        // that slot and changes the collection version in the same MDK transaction.
        // This last read also catches a block the Swift timeline has not received yet.
        guard try await scope.stillRetains(bookmark.target, in: appState),
              try await scope.version(in: appState).changeSince(previous: baseline) != .restartRequired else {
            throw AttachmentReadError.stale
        }
        let (row, item) = try current()
        var restored = TranscriptMediaTarget(item: item.forTranscriptPage, scope: .init(model, appState: appState),
            initialData: data, row: row, media: [], gifRowID: item.isGIF ? row.id : nil)
        restored.restored = true
        target = restored
    }
}

struct TranscriptMediaSessionView<Content: View>: View {
    let session: TranscriptMediaSession
    let conversation: ConversationViewModel
    let onDismiss: () -> Void
    @ViewBuilder let content: (TranscriptMediaTarget) -> Content
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var phase

    private struct Context: Equatable {
        let scope: MessageBubble.MediaOpenScope
        let runtime: Int?
        let owner: AttachmentHistoryPager.Scope?
        let window: ConversationViewModel.WindowRuntime?
        let phase: ScenePhase
        let active: Bool
    }

    private var context: Context {
        Context(scope: .init(conversation, appState: appState), runtime: appState.runtimeEventsGeneration,
            owner: .init(ownerOf: appState, group: conversation.group.groupIdHex),
            window: conversation.windowRuntime, phase: phase, active: appState.isAppSceneActive)
    }

    var body: some View {
        let now = context
        Group {
            if let target = session.target, target.scope == now.scope, now.owner?.runtimeGeneration == target.scope.generation, phase != .background {
                content(target)
            } else {
                ProgressView()
            }
        }
        .task(id: now) {
            guard session.originalScope.matchesConversation(now.scope) else { onDismiss(); return }
            // The old runtime's decoded image, player, sheets and prepared bytes leave
            // the hierarchy immediately. Keep only the original selected slot for revalidation.
            if now.owner == nil || phase == .background || session.target?.scope != now.scope {
                session.suspend()
            }
            guard session.target == nil, phase == .active, now.active, let generation = now.runtime else { return }
            if now.window == .failed(generation) { onDismiss(); return }
            guard now.window == .ready(generation) else { return }
            do { try await session.restore(in: conversation, appState: appState) }
            catch { if !Task.isCancelled, context == now { onDismiss() } }
        }
    }
}

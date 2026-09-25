import Foundation
import MarmotKit
import Observation

typealias DraftMediaUpload = Task<MediaAttachmentReferenceFfi?, Never>

nonisolated enum DraftMediaUploadState: Equatable {
    case uploading
    case uploaded
    case failed
}

@Observable
@MainActor
final class DraftMediaPreuploads {
    typealias Uploader = @MainActor (_ accountRef: String, _ attachment: MediaDraftAttachment) async throws
        -> MediaAttachmentReferenceFfi?

    private struct Entry {
        let accountRef: String
        let token: UUID
        let task: DraftMediaUpload
    }

    private(set) var states: [MediaDraftAttachment.ID: DraftMediaUploadState] = [:]
    @ObservationIgnored private let uploader: Uploader
    @ObservationIgnored private var entries: [MediaDraftAttachment.ID: Entry] = [:]

    init(uploader: @escaping Uploader) {
        self.uploader = uploader
    }

    func reconcile(_ attachments: [MediaDraftAttachment], accountRef: String?) {
        let wantedIds = accountRef == nil ? [] : Set(attachments.map(\.id))
        let dropped = entries.filter { !wantedIds.contains($0.key) || $0.value.accountRef != accountRef }
        for (id, entry) in dropped {
            entry.task.cancel()
            entries[id] = nil
            states[id] = nil
        }
        guard let accountRef else { return }
        for attachment in attachments where entries[attachment.id] == nil {
            let uploader = uploader
            let token = UUID()
            let task = DraftMediaUpload { [weak self] in
                let uploaded = try? await uploader(accountRef, attachment)
                let reference = Task.isCancelled ? nil : uploaded ?? nil
                self?.settle(attachment.id, token: token, reference: reference)
                return reference
            }
            entries[attachment.id] = Entry(accountRef: accountRef, token: token, task: task)
            states[attachment.id] = .uploading
        }
    }

    private func settle(_ id: MediaDraftAttachment.ID, token: UUID, reference: MediaAttachmentReferenceFfi?) {
        guard entries[id]?.token == token else { return }
        states[id] = reference == nil ? .failed : .uploaded
    }

    func take(_ attachments: [MediaDraftAttachment], accountRef: String) -> [DraftMediaUpload?] {
        attachments.map { attachment in
            states[attachment.id] = nil
            guard let entry = entries.removeValue(forKey: attachment.id) else { return nil }
            guard entry.accountRef == accountRef else {
                entry.task.cancel()
                return nil
            }
            return entry.task
        }
    }

    func cancelAll() {
        for entry in entries.values {
            entry.task.cancel()
        }
        entries.removeAll()
        states.removeAll()
    }
}

nonisolated enum DraftMediaPreuploadResolution {
    static func reusable(
        _ reference: MediaAttachmentReferenceFfi?,
        currentEpoch: UInt64?
    ) -> MediaAttachmentReferenceFfi? {
        guard let reference else { return nil }
        if let currentEpoch, reference.sourceEpoch != currentEpoch { return nil }
        return reference
    }

    static func merged(
        _ attachments: [MediaDraftAttachment],
        prepared: [MediaAttachmentReferenceFfi?],
        uploaded: [MediaAttachmentReferenceFfi]
    ) -> (attachments: [MediaDraftAttachment], references: [MediaAttachmentReferenceFfi]) {
        var remaining = uploaded[...]
        var kept: [MediaDraftAttachment] = []
        var references: [MediaAttachmentReferenceFfi] = []
        for (attachment, reference) in zip(attachments, prepared) {
            guard let resolved = reference ?? remaining.popFirst() else { continue }
            kept.append(attachment)
            references.append(resolved)
        }
        return (kept, references)
    }
}

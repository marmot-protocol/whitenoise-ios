import Foundation
import MarmotKit

extension MarmotClient {
    func attachmentPreview(accountRef: String, groupID: String) async throws -> AttachmentPageFfi {
        let result = try await marmot.attachmentHistoryPage(accountRef: accountRef,
            groupIdHex: groupID, limit: 100, cursor: nil)
        guard case .page(let page) = result else { throw AttachmentReadError.stale }
        return page
    }

    /// Every chunk revalidates the opaque reference against current visibility.
    func attachmentData(accountRef: String, groupID: String,
                        target: AttachmentLocalTargetFfi) async throws -> Data? {
        let assets = try await marmot.attachmentLocalAssets(accountRef: accountRef,
            groupIdHex: groupID, targets: [target])
        guard let asset = assets.first, let reference = asset.reference else { return nil }
        guard asset.byteCount <= 512 * 1024 * 1024 else { throw AttachmentReadError.tooLarge }
        return try await RetainedAttachmentReader.read(byteCount: asset.byteCount) { offset, limit in
            try await self.marmot.readAttachmentAsset(accountRef: accountRef,
                reference: reference, offset: offset, limit: limit)
        }
    }
}

nonisolated enum AttachmentReadError: Error {
    case stale
    case tooLarge
    case unavailable
}

extension MarmotClient {
    func acquireAttachmentData(accountRef: String, groupID: String, target: AttachmentLocalTargetFfi,
                               explicit: Bool) async throws -> Data? {
        if let data = try await attachmentData(accountRef: accountRef, groupID: groupID, target: target) { return data }
        let status = try await marmot.attachmentTransferSnapshot(accountRef: accountRef,
            groupIdHex: groupID, targets: [target]).items.first
        guard let status, status.state != .unavailable else { throw AttachmentReadError.unavailable }
        if !explicit, [.removed, .cancelled, .failed, .policyBlocked].contains(status.state) {
            throw AttachmentReadError.unavailable
        }
        // Partial per-type/network policies cannot enqueue an automatic MDK job yet.
        // Keep the existing visible-media path instead of escalating an automatic fetch to explicit work.
        if !explicit, [.notRequested, .paused].contains(status.state) { return nil }
        if [.notRequested, .paused, .removed, .cancelled, .failed, .policyBlocked].contains(status.state) {
            guard try await marmot.downloadAttachmentAgain(accountRef: accountRef, groupIdHex: groupID,
                target: target) != nil else { throw AttachmentReadError.unavailable }
        }
        let subscription = try await marmot.subscribeAttachmentTransfers(accountRef: accountRef,
            groupIdHex: groupID, targets: [target])
        return try await withTaskCancellationHandler {
            defer { subscription.cancel() }
            while let snapshot = try await subscription.next() {
                try Task.checkCancellation()
                guard let current = snapshot.items.first else { throw AttachmentReadError.unavailable }
                switch current.state {
                case .ready:
                    guard let data = try await attachmentData(accountRef: accountRef, groupID: groupID, target: target)
                    else { throw AttachmentReadError.stale }
                    return data
                case .unavailable, .cancelled, .removed, .failed, .policyBlocked, .paused:
                    throw AttachmentReadError.unavailable
                default: break
                }
            }
            throw AttachmentReadError.unavailable
        } onCancel: {
            subscription.cancel()
        }
    }
}

nonisolated enum RetainedAttachmentReader {
    static func read(byteCount: UInt64,
                     chunk: (UInt64, UInt32) async throws -> AttachmentLocalBytesFfi) async throws -> Data {
        guard byteCount <= 512 * 1024 * 1024 else { throw AttachmentReadError.tooLarge }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let next = try await chunk(UInt64(data.count), 1024 * 1024)
            guard next.available else { throw AttachmentReadError.stale }
            if next.bytes.isEmpty {
                guard UInt64(data.count) == byteCount else { throw AttachmentReadError.stale }
                return data
            }
            guard UInt64(data.count) + UInt64(next.bytes.count) <= byteCount else { throw AttachmentReadError.stale }
            data.append(next.bytes)
        }
    }
}

extension MarmotClient {
    /// Reply previews omit the original source event ID. Resolve their original slot locally.
    func resolveAttachmentTarget(accountRef: String, groupID: String,
                                 hint: AttachmentSourceHint) async throws -> AttachmentLocalTargetFfi {
        var cursor: AttachmentHistoryCursor?
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AttachmentReadError.unavailable }
            let result = try await marmot.attachmentHistoryPage(accountRef: accountRef,
                groupIdHex: groupID, limit: 100, cursor: cursor)
            guard case .page(let page) = result else { throw AttachmentReadError.stale }
            for entry in page.entries where entry.messageIdHex == hint.messageID {
                if case .accepted(let index, _) = entry.attachment, index == hint.slot {
                    return AttachmentLocalTargetFfi(messageIdHex: entry.messageIdHex,
                        sourceMessageIdHex: entry.sourceMessageIdHex, attachmentIndex: index)
                }
            }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        throw AttachmentReadError.unavailable
    }
}

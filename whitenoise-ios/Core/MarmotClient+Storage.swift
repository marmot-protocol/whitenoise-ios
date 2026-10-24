import Foundation
import MarmotKit

/// Manage Storage reads and bulk removals. The generated calls are async and
/// suspend rather than block, so these forward directly; MDK owns the bytes.
extension MarmotClient {
    func attachmentStorageUsage(accountRef: String) async throws -> AttachmentStorageUsageFfi {
        try await marmot.attachmentStorageUsage(accountRef: accountRef)
    }

    func attachmentStorageByChat(accountRef: String, limit: UInt32,
                                 cursor: ChatStorageCursor?) async throws -> ChatStoragePageFfi {
        try await marmot.attachmentStorageByChat(accountRef: accountRef, limit: limit, cursor: cursor)
    }

    func largestRetainedAttachments(accountRef: String, groupIdHex: String?, limit: UInt32,
                                    cursor: RetainedAttachmentsCursor?) async throws -> RetainedAttachmentsPageFfi {
        try await marmot.largestRetainedAttachments(accountRef: accountRef, groupIdHex: groupIdHex,
                                                    limit: limit, cursor: cursor)
    }

    func removeChatAttachments(accountRef: String, groupIdHex: String) async throws -> UInt64 {
        try await marmot.removeChatAttachments(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func removeAttachmentsOlderThan(accountRef: String, receivedBefore: UInt64,
                                    groupIdHex: String?) async throws -> UInt64 {
        try await marmot.removeAttachmentsOlderThan(accountRef: accountRef, receivedBefore: receivedBefore,
                                                    groupIdHex: groupIdHex)
    }

    /// One listing entry goes through the same Remove as a message's Downloads.
    /// Returns false when the attachment no longer reads locally.
    func removeRetainedAttachment(accountRef: String, groupIdHex: String,
                                  target: AttachmentLocalTargetFfi) async throws -> Bool {
        let assets = try await marmot.attachmentLocalAssets(accountRef: accountRef,
            groupIdHex: groupIdHex, targets: [target])
        guard let reference = assets.first?.reference else { return false }
        return try await marmot.controlAttachment(accountRef: accountRef, reference: reference, control: .remove)
    }

    /// The plaintext hash the host media cache keys a listing entry's decrypted
    /// copy by. Local references are opaque, so this reads the chat's attachment
    /// history, which still names a removed attachment. Nil when it can't be found.
    func retainedAttachmentPlaintextHash(accountRef: String, groupIdHex: String,
                                         target: AttachmentLocalTargetFfi) async throws -> String? {
        var cursor: AttachmentHistoryCursor?
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        repeat {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { return nil }
            let result = try await marmot.attachmentHistoryPage(accountRef: accountRef,
                groupIdHex: groupIdHex, limit: 100, cursor: cursor)
            guard case .page(let page) = result else { return nil }
            if let hash = Self.plaintextHash(in: page.entries, for: target) { return hash }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        return nil
    }

    /// Only the original message, source and slot name the same attachment.
    static func plaintextHash(in entries: [AttachmentEntryFfi], for target: AttachmentLocalTargetFfi) -> String? {
        for entry in entries where entry.messageIdHex == target.messageIdHex
            && entry.sourceMessageIdHex == target.sourceMessageIdHex {
            if case .accepted(let index, let reference) = entry.attachment, index == target.attachmentIndex {
                return reference.plaintextSha256
            }
        }
        return nil
    }

    func clearAvatarCache(accountRef: String) async throws {
        try await marmot.clearAvatarCache(accountRef: accountRef)
    }
}

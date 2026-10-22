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

    func clearAvatarCache(accountRef: String) async throws {
        try await marmot.clearAvatarCache(accountRef: accountRef)
    }
}

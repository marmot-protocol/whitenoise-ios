import Foundation
import MarmotKit

/// MDK has one automatic gate; the host keeps its stricter type/network choices.
@MainActor
enum AttachmentPolicyBridge {
    private static var tail: Task<Void, Error>?

    static func synchronize(_ client: MarmotClient, beforeStart: Bool = false,
                            updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)? = nil) async throws {
        guard client.cursorPersistence == .advance else { return }
        let previous = tail
        let task = Task { @MainActor in
            _ = try? await previous?.value
            let accounts = try await client.listAccounts()
            var appliedLimits = updatedLimits == nil
            for account in accounts where !account.signedOut {
                do {
                    if let checkpoint = try await client.onboardingSnapshot(accountID: account.accountIdHex), !checkpoint.ready { continue }
                } catch is CancellationError { throw CancellationError() }
                catch { continue } // Unreadable identities are excluded from normal activation.
                let allowed = !beforeStart && MediaAutoDownloadStore.shared
                    .allowsBackgroundAttachments(accountID: account.accountIdHex)
                var policy = try await client.marmot.attachmentDownloadPolicy(accountRef: account.accountIdHex)
                let old = policy
                if let limits = updatedLimits, limits.account == account.accountIdHex || limits.account == account.label {
                    appliedLimits = true
                    policy.retainedBytes = limits.policy.retainedBytes
                    policy.diskReserve = limits.policy.diskReserve
                    policy.transferLimit = limits.policy.transferLimit
                }
                policy.automatic = allowed
                if policy != old {
                    try await client.marmot.setAttachmentDownloadPolicy(accountRef: account.accountIdHex, policy: policy)
                }
            }
            guard appliedLimits else { throw AttachmentReadError.unavailable }
        }
        tail = task
        try await task.value
    }
}

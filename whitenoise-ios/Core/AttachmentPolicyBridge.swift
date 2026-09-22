import Foundation
import MarmotKit

/// Revokes in event order; obsolete policy evaluations never grant a newer generation.
@MainActor
enum AttachmentPolicyBridge {
    private static weak var activeClient: MarmotClient?
    private static var revision: UInt64 = 0
    private static var policyTail: Task<Void, Error>?
    private static var revocationTail: Task<[(AccountSummaryFfi, String)], Error>?

    static func policyDidChange() {
        guard let client = activeClient else { return }
        let task = schedule(client, beforeStart: false, updatedLimits: nil)
        Task { _ = try? await task.value }
    }

    static func synchronize(_ client: MarmotClient, beforeStart: Bool = false,
                            updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)? = nil) async throws {
        guard client.cursorPersistence == .advance else { return }
        activeClient = client
        try await schedule(client, beforeStart: beforeStart, updatedLimits: updatedLimits).value
    }

    private static func schedule(_ client: MarmotClient, beforeStart: Bool,
                                 updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)?) -> Task<Void, Error> {
        revision &+= 1
        let event = revision
        let previous = revocationTail
        let revocation = Task { @MainActor in
            _ = try? await previous?.value
            let accounts = try await client.listAccounts()
            var generations: [(AccountSummaryFfi, String)] = []
            for account in accounts where !account.signedOut {
                do {
                    let generation = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.accountIdHex)
                    generations.append((account, generation))
                } catch MarmotKitError.AttachmentAccountSignedOut { continue }
            }
            return generations
        }
        revocationTail = revocation
        let previousPolicy = policyTail
        let application = Task { @MainActor in
            let generations = try await revocation.value
            // Keep durable quota writes ordered while revocation runs promptly.
            _ = try? await previousPolicy?.value
            var appliedLimits = updatedLimits == nil
            var appliedPermission = false
            for (account, generation) in generations {
                do {
                    if let checkpoint = try await client.onboardingSnapshot(accountID: account.accountIdHex), !checkpoint.ready { continue }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
                guard revision == event, activeClient === client else {
                    if updatedLimits != nil { throw CancellationError() }
                    return
                }
                var policy = try await client.marmot.attachmentDownloadPolicy(accountRef: account.accountIdHex)
                let old = policy
                if let limits = updatedLimits, limits.account == account.accountIdHex || limits.account == account.label {
                    appliedLimits = true
                    policy.retainedBytes = limits.policy.retainedBytes
                    policy.diskReserve = limits.policy.diskReserve
                    policy.transferLimit = limits.policy.transferLimit
                }
                // Previous iOS versions used this flag as an all-category network gate.
                // HostManaged's runtime permission now owns that decision.
                policy.automatic = true
                guard revision == event, activeClient === client else {
                    if updatedLimits != nil { throw CancellationError() }
                    return
                }
                if policy != old {
                    try await client.marmot.setAttachmentDownloadPolicy(accountRef: account.accountIdHex, policy: policy)
                }
                guard !beforeStart, revision == event, activeClient === client else { continue }
                let permission = MediaAutoDownloadStore.shared.attachmentPermission(accountID: account.accountIdHex)
                // A stale generation is consumed as-is; never mint a replacement for this event.
                let applied = try await client.marmot.setAttachmentAutomaticPermission(accountRef: account.accountIdHex,
                    generation: generation, permission: permission)
                appliedPermission = appliedPermission || applied
            }
            if appliedPermission, revision == event, activeClient === client {
                MediaAutoDownloadStore.shared.didApplyAttachmentPermission()
            }
            guard appliedLimits else { throw AttachmentReadError.unavailable }
        }
        policyTail = application
        return application
    }
}

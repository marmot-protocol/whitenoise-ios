import Foundation
import MarmotKit

/// The runtime operations `AttachmentPolicyBridge` orders. `MarmotClient`
/// conforms; tests substitute a fake to observe the order.
protocol AttachmentPolicyRuntime: AnyObject {
    var cursorPersistence: CursorPersistenceFfi { get }
    func listAccounts() async throws -> [AccountSummaryFfi]
    func onboardingSnapshot(accountID: String) async throws -> OnboardingSnapshotFfi?
    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String
    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi
    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws
    func setAttachmentAutomaticPermission(accountRef: String, generation: String,
                                          permission: AttachmentAutomaticPermissionFfi) async throws -> Bool
}

/// Where the bridge reads each account's captured permission and reports that
/// one was applied. `MediaAutoDownloadStore` conforms.
protocol AttachmentPermissionSource: AnyObject {
    func attachmentPermission(accountID: String) -> AttachmentAutomaticPermissionFfi
    func didApplyAttachmentPermission()
}

nonisolated extension MarmotClient: AttachmentPolicyRuntime {
    func beginAttachmentPermissionUpdate(accountRef: String) async throws -> String {
        try await marmot.beginAttachmentPermissionUpdate(accountRef: accountRef)
    }

    func attachmentDownloadPolicy(accountRef: String) async throws -> AttachmentDownloadPolicyFfi {
        try await marmot.attachmentDownloadPolicy(accountRef: accountRef)
    }

    func setAttachmentDownloadPolicy(accountRef: String, policy: AttachmentDownloadPolicyFfi) async throws {
        try await marmot.setAttachmentDownloadPolicy(accountRef: accountRef, policy: policy)
    }

    func setAttachmentAutomaticPermission(accountRef: String, generation: String,
                                          permission: AttachmentAutomaticPermissionFfi) async throws -> Bool {
        try await marmot.setAttachmentAutomaticPermission(accountRef: accountRef, generation: generation,
                                                          permission: permission)
    }
}

extension MediaAutoDownloadStore: AttachmentPermissionSource {}

/// Revokes in event order; obsolete policy evaluations never grant a newer generation.
@MainActor
final class AttachmentPolicyBridge {
    static let shared = AttachmentPolicyBridge()

    /// The runtime currently targeted by `synchronize`. Not exposed to
    /// `NWPathMonitor`'s `policyDidChange()` until `clientAcceptsPolicyChanges`
    /// is enabled by a post-start sync (never during `beforeStart: true`).
    /// `reconciledClient` tracks the runtime whose post-start policy sync
    /// actually succeeded so a failed sync is retried on the next activation.
    private weak var currentClient: (any AttachmentPolicyRuntime)?
    private weak var reconciledClient: (any AttachmentPolicyRuntime)?
    private var clientAcceptsPolicyChanges = false
    private var revision: UInt64 = 0
    private var policyTail: Task<Void, Error>?
    private var revocationTail: Task<[(AccountSummaryFfi, String)], Error>?
    private let permissions: @MainActor () -> any AttachmentPermissionSource

    /// `permissions` is read per event so the shared bridge and
    /// `MediaAutoDownloadStore.shared` can refer to each other.
    init(permissions: @escaping @MainActor () -> any AttachmentPermissionSource = { MediaAutoDownloadStore.shared }) {
        self.permissions = permissions
    }

    func policyDidChange() {
        guard clientAcceptsPolicyChanges, let client = currentClient else { return }
        let task = schedule(client, beforeStart: false, updatedLimits: nil)
        Task { _ = try? await task.value }
    }

    func isAttached(to client: any AttachmentPolicyRuntime) -> Bool {
        currentClient === client && clientAcceptsPolicyChanges && reconciledClient === client
    }

    /// Detaches `client` so `NWPathMonitor` / preference updates cannot race
    /// `shutdownAndClose()`, and cancels in-flight bridge work. Returns the
    /// cancelled policy tail so lifecycle cleanup can drain it after storage
    /// closes.
    @discardableResult
    func detach(client: any AttachmentPolicyRuntime) -> Task<Void, Error>? {
        guard currentClient === client else { return nil }
        currentClient = nil
        reconciledClient = nil
        clientAcceptsPolicyChanges = false
        revision &+= 1
        let revoked = revocationTail
        let tail = policyTail
        revocationTail = nil
        policyTail = nil
        revoked?.cancel()
        tail?.cancel()
        return tail
    }

    func synchronize(_ client: any AttachmentPolicyRuntime, beforeStart: Bool = false,
                     updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)? = nil) async throws {
        guard client.cursorPersistence == .advance else { return }
        if currentClient !== client {
            reconciledClient = nil
        }
        currentClient = client
        clientAcceptsPolicyChanges = !beforeStart
        try await schedule(client, beforeStart: beforeStart, updatedLimits: updatedLimits).value
    }

    private func schedule(_ client: any AttachmentPolicyRuntime, beforeStart: Bool,
                          updatedLimits: (account: String, policy: AttachmentDownloadPolicyFfi)?) -> Task<Void, Error> {
        revision &+= 1
        let event = revision
        if !beforeStart, reconciledClient === client {
            reconciledClient = nil
        }
        let previous = revocationTail
        let revocation = Task { @MainActor in
            _ = try? await previous?.value
            try Task.checkCancellation()
            let accounts = try await client.listAccounts()
            var generations: [(AccountSummaryFfi, String)] = []
            for account in accounts where !account.signedOut {
                try Task.checkCancellation()
                do {
                    let generation = try await client.beginAttachmentPermissionUpdate(accountRef: account.accountIdHex)
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
            try Task.checkCancellation()
            let limitsEdited = updatedLimits != nil
            var appliedLimits = false
            var appliedPermission = false
            var reconciledAllEligibleAccounts = true
            for (account, generation) in generations {
                try Task.checkCancellation()
                do {
                    let checkpoint = try await client.onboardingSnapshot(accountID: account.accountIdHex)
                    guard Self.configures(onboardingReady: checkpoint?.ready) else { continue }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    reconciledAllEligibleAccounts = false
                    continue
                }
                guard !Task.isCancelled, revision == event, currentClient === client else {
                    try Self.endSupersededEvent(limitsEdited: limitsEdited)
                    return
                }
                let old = try await client.attachmentDownloadPolicy(accountRef: account.accountIdHex)
                let update = Self.policy(old, for: account, applying: updatedLimits)
                appliedLimits = appliedLimits || update.appliesLimits
                guard !Task.isCancelled, revision == event, currentClient === client else {
                    try Self.endSupersededEvent(limitsEdited: limitsEdited)
                    return
                }
                if update.policy != old {
                    try await client.setAttachmentDownloadPolicy(accountRef: account.accountIdHex,
                                                                 policy: update.policy)
                }
                guard Self.grantsPermission(
                    beforeStart: beforeStart,
                    isCurrentEvent: !Task.isCancelled && revision == event && currentClient === client
                ) else { continue }
                let permission = permissions().attachmentPermission(accountID: account.accountIdHex)
                // A stale generation is consumed as-is; never mint a replacement for this event.
                let applied = try await client.setAttachmentAutomaticPermission(accountRef: account.accountIdHex,
                    generation: generation, permission: permission)
                if !applied { reconciledAllEligibleAccounts = false }
                appliedPermission = appliedPermission || applied
            }
            if appliedPermission, !Task.isCancelled, revision == event, currentClient === client {
                permissions().didApplyAttachmentPermission()
            }
            try Self.finishEvent(limitsEdited: limitsEdited, appliedLimits: appliedLimits)
            if reconciledAllEligibleAccounts, !beforeStart, !Task.isCancelled, revision == event, currentClient === client {
                self.reconciledClient = client
            }
        }
        policyTail = application
        return application
    }

    /// Accounts still in onboarding keep their stored policy and are not granted
    /// the permission again until they are ready; an account with no checkpoint
    /// is configured.
    nonisolated static func configures(onboardingReady: Bool?) -> Bool {
        onboardingReady ?? true
    }

    /// Ends an event that a newer event or a replaced client superseded. A save
    /// of edited limits fails as cancelled, so Settings never reports it as
    /// saved; a background resync just stops.
    nonisolated static func endSupersededEvent(limitsEdited: Bool) throws {
        if limitsEdited { throw CancellationError() }
    }

    /// The captured permission is granted only by the current event, and never
    /// by a `beforeStart` sync, which writes policy only.
    nonisolated static func grantsPermission(beforeStart: Bool, isCurrentEvent: Bool) -> Bool {
        !beforeStart && isCurrentEvent
    }

    /// A save of edited limits that matched no configurable account fails, so
    /// Settings reports the save as failed instead of saved.
    nonisolated static func finishEvent(limitsEdited: Bool, appliedLimits: Bool) throws {
        if limitsEdited, !appliedLimits { throw AttachmentReadError.unavailable }
    }

    /// The policy to store for `account`: edited limits only when they name this
    /// account by key or label, and `automatic` always on.
    nonisolated static func policy(
        _ current: AttachmentDownloadPolicyFfi,
        for account: AccountSummaryFfi,
        applying limits: (account: String, policy: AttachmentDownloadPolicyFfi)?
    ) -> (policy: AttachmentDownloadPolicyFfi, appliesLimits: Bool) {
        var policy = current
        var appliesLimits = false
        if let limits, limits.account == account.accountIdHex || limits.account == account.label {
            appliesLimits = true
            policy.retainedBytes = limits.policy.retainedBytes
            policy.diskReserve = limits.policy.diskReserve
            policy.transferLimit = limits.policy.transferLimit
        }
        // Previous iOS versions used this flag as an all-category network gate.
        // HostManaged's runtime permission now owns that decision.
        policy.automatic = true
        return (policy, appliesLimits)
    }
}

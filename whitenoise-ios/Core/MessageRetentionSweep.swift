import Foundation
import MarmotKit

/// Pure decisions for the foreground expiration sweep: which accounts and
/// groups to visit and whether a pass may touch the runtime at all.
nonisolated enum MessageRetentionSweepPolicy {

    static let sweepIntervalNanoseconds: UInt64 = 30_000_000_000

    /// A pass needs a live foreground runtime with an active account; the
    /// local-foreground gate already folds scene, suspension, and client state.
    static func canSweep(
        phase: AppState.Phase,
        canUseRuntimeForLocalForegroundWork: Bool
    ) -> Bool {
        phase == .ready && canUseRuntimeForLocalForegroundWork
    }

    static func sweepAccountRefs(from accounts: [AccountSummaryFfi]) -> [String] {
        accounts.filter { !$0.signedOut }.map(\.label)
    }

    static func sweepGroupIds(from groups: [AppGroupRecordFfi]) -> [String] {
        var seen = Set<String>()
        return groups
            .filter { $0.disappearingMessageSecs > 0 && seen.insert($0.groupIdHex).inserted }
            .map(\.groupIdHex)
    }
}

nonisolated enum MessageRetentionSweep {
    struct Outcome {
        var prunedGroupIds: Set<String> = []
        var prunedMessageCount: UInt64 = 0
        var mediaPlaintextHashes: Set<String> = []
        var requiresFullMediaPurge = false
    }

    /// One sweep pass delegates expiry eligibility to Marmot so unread-message,
    /// clock-skew, and bounded-scan deferrals stay engine-owned. MDK owns retained
    /// bytes; a media expiry also clears legacy host caches without scanning history.
    static func run(
        client: MarmotClient,
        groupsByAccountRef: [String: [AppGroupRecordFfi]],
        nowMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) async -> Outcome {
        var outcome = Outcome()
        for accountRef in groupsByAccountRef.keys.sorted() {
            guard !Task.isCancelled else { break }
            guard !Task.isCancelled,
                  let report = try? await client.sweepExpiredRetention(
                    accountRef: accountRef,
                    nowMs: nowMs
                  )
            else { continue }
            for group in report.groups {
                let ciphertextHashes = Set(group.mediaCiphertextSha256.map { $0.lowercased() })
                if group.prunedMessages > 0 || !ciphertextHashes.isEmpty {
                    outcome.prunedGroupIds.insert(group.groupIdHex)
                    outcome.prunedMessageCount &+= group.prunedMessages
                }
                if !ciphertextHashes.isEmpty { outcome.requiresFullMediaPurge = true }
            }
        }
        return outcome
    }

    /// One-shot snapshot loading for background maintenance. The foreground
    /// sweeper retains its subscriptions separately across periodic passes.
    static func loadGroupSnapshots(
        client: MarmotClient,
        accountRefs: [String]
    ) async -> [String: [AppGroupRecordFfi]] {
        var groupsByAccountRef: [String: [AppGroupRecordFfi]] = [:]
        for accountRef in accountRefs {
            guard !Task.isCancelled else { break }
            guard let subscription = try? await client.subscribeChats(
                accountRef: accountRef,
                includeArchived: true
            ) else { continue }
            groupsByAccountRef[accountRef] = await client.chatsSubscriptionSnapshot(subscription)
        }
        return groupsByAccountRef
    }
}

/// Retains one live group subscription and folds its updates into the initial
/// one-shot snapshot. `ChatsSubscription.snapshot()` is consumed exactly once;
/// later sweep passes read this cache while the update task keeps it current.
@MainActor
private final class MessageRetentionGroupSubscription {
    private var groupsById: [String: AppGroupRecordFfi]
    private var updateTask: Task<Void, Never>?

    init(subscription: ChatsSubscription, initialGroups: [AppGroupRecordFfi]) {
        groupsById = Dictionary(
            initialGroups.map { ($0.groupIdHex, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        updateTask = Task { [weak self, subscription] in
            for await group in SubscriptionDriver.chats(subscription) {
                guard !Task.isCancelled else { return }
                self?.groupsById[group.groupIdHex] = group
            }
        }
    }

    deinit {
        updateTask?.cancel()
    }

    var groups: [AppGroupRecordFfi] {
        Array(groupsById.values)
    }

    func cancel() {
        updateTask?.cancel()
        updateTask = nil
    }
}

/// Owns the foreground expiration-sweep loop: one pass on start (foreground
/// resume / ready maintenance), then periodic passes while the runtime stays
/// available. Cancelled alongside the other foreground maintenance when the
/// app suspends.
@MainActor
final class MessageRetentionSweeper {
    private var sweepTask: Task<Void, Never>?
    private var groupSubscriptionsByAccountRef: [String: MessageRetentionGroupSubscription] = [:]
    private var pendingMediaPlaintextHashes: Set<String> = []
    private var pendingFullMediaPurge = false
    private weak var appState: AppState?

    deinit {
        sweepTask?.cancel()
    }

    /// Live only while an uncancelled sweep loop exists; `cancelWithoutAwaiting`
    /// leaves the task reference behind, so a bare nil-check would lie.
    var isSweeping: Bool { !(sweepTask?.isCancelled ?? true) }

    func start(appState: AppState) {
        self.appState = appState
        guard appState.phase == .ready else { return }
        let previousTask = sweepTask
        previousTask?.cancel()
        cancelGroupSubscriptions()
        sweepTask = Task { [weak self] in
            // Drain the prior loop so two passes can never overlap.
            await previousTask?.value
            self?.cancelGroupSubscriptions()
            await self?.runSweepLoop()
        }
    }

    func cancelWithoutAwaiting() {
        sweepTask?.cancel()
        cancelGroupSubscriptions()
    }

    func cancel() async {
        let task = sweepTask
        sweepTask = nil
        task?.cancel()
        cancelGroupSubscriptions()
        await task?.value
        if sweepTask == nil {
            cancelGroupSubscriptions()
        }
    }

    private func runSweepLoop() async {
        while !Task.isCancelled {
            await sweepOnce()
            do {
                try await Task.sleep(nanoseconds: MessageRetentionSweepPolicy.sweepIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func sweepOnce() async {
        guard let appState,
              MessageRetentionSweepPolicy.canSweep(
                phase: appState.phase,
                canUseRuntimeForLocalForegroundWork: appState.canUseRuntimeForLocalForegroundWork
              ),
              let client = try? appState.currentMarmotClient()
        else { return }
        if pendingFullMediaPurge {
            if await MessageMediaCache.purgeAllDecryptedMedia() {
                pendingFullMediaPurge = false
                pendingMediaPlaintextHashes.removeAll()
            }
        } else if !pendingMediaPlaintextHashes.isEmpty,
                  await MessageMediaCache.removeCachedData(
                    forPlaintextHashes: pendingMediaPlaintextHashes
                  ) {
            pendingMediaPlaintextHashes.removeAll()
        }
        let accountRefs = MessageRetentionSweepPolicy.sweepAccountRefs(from: appState.accounts)
        guard !accountRefs.isEmpty else { return }
        let groupsByAccountRef = await groupSnapshots(client: client, accountRefs: accountRefs)
        let outcome = await MessageRetentionSweep.run(
            client: client,
            groupsByAccountRef: groupsByAccountRef
        )
        if outcome.requiresFullMediaPurge {
            if await MessageMediaCache.purgeAllDecryptedMedia() {
                pendingFullMediaPurge = false
                pendingMediaPlaintextHashes.removeAll()
            } else {
                pendingFullMediaPurge = true
            }
        } else if !outcome.mediaPlaintextHashes.isEmpty,
                  !(await MessageMediaCache.removeCachedData(
                    forPlaintextHashes: outcome.mediaPlaintextHashes
                  )) {
            pendingMediaPlaintextHashes.formUnion(outcome.mediaPlaintextHashes)
        }
        guard !Task.isCancelled, !outcome.prunedGroupIds.isEmpty else { return }
        appState.noteRetentionSweepCompleted(prunedGroupIds: outcome.prunedGroupIds)
    }

    private func groupSnapshots(
        client: MarmotClient,
        accountRefs: [String]
    ) async -> [String: [AppGroupRecordFfi]] {
        let currentAccounts = Set(accountRefs)
        let removedAccountRefs = groupSubscriptionsByAccountRef.keys.filter {
            !currentAccounts.contains($0)
        }
        for accountRef in removedAccountRefs {
            groupSubscriptionsByAccountRef.removeValue(forKey: accountRef)?.cancel()
        }

        var groupsByAccountRef: [String: [AppGroupRecordFfi]] = [:]
        for accountRef in accountRefs {
            guard !Task.isCancelled else { break }
            let state: MessageRetentionGroupSubscription
            if let existing = groupSubscriptionsByAccountRef[accountRef] {
                state = existing
            } else {
                guard let created = try? await client.subscribeChats(
                    accountRef: accountRef,
                    includeArchived: true
                ) else { continue }
                let initialGroups = await client.chatsSubscriptionSnapshot(created)
                guard !Task.isCancelled else { break }
                let createdState = MessageRetentionGroupSubscription(
                    subscription: created,
                    initialGroups: initialGroups
                )
                groupSubscriptionsByAccountRef[accountRef] = createdState
                state = createdState
            }
            groupsByAccountRef[accountRef] = state.groups
        }
        return groupsByAccountRef
    }

    private func cancelGroupSubscriptions() {
        for state in groupSubscriptionsByAccountRef.values {
            state.cancel()
        }
        groupSubscriptionsByAccountRef.removeAll()
    }
}

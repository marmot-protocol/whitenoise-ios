import SwiftUI
import MarmotKit

/// Live block-list store for one signed-in account.
///
/// MDK owns the block list, its publication, and the hiding it implies; this
/// only mirrors the durable snapshot so SwiftUI can render it and offer the two
/// mutations. Screens that act on a single person pass that person as `target`
/// so the resolved account id is available alongside the list.
@MainActor
@Observable
final class BlockedUsersModel {
    private(set) var users: [BlockedUserFfi] = []
    private(set) var isLoaded = false
    /// The mutation currently publishing, so a surface can name which way it
    /// is going instead of only reporting that something is busy.
    private(set) var savingIntent: (id: String, blocked: Bool)?
    private(set) var error: String?
    private(set) var targetId: String?
    private(set) var uncertainIntent: (id: String, blocked: Bool)?
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var ownerAccount: String?
    /// The reference `targetId` was resolved from. A re-subscription for the
    /// same account and the same person keeps the snapshot on screen; anything
    /// else has a different subject and must reload before it claims one.
    @ObservationIgnored private var resolvedTargetReference: String?

    /// Lowercased account ids in the current snapshot. Block state is compared
    /// case-insensitively so a differently-cased hex from the reference
    /// resolver can never read as "not blocked".
    var blockedAccountIds: Set<String> {
        Set(users.map { $0.publicKey.lowercased() })
    }

    func isConfirmedBlocked(_ userId: String, accountRef: String?) -> Bool {
        isLoaded && ownerAccount == accountRef && blockedAccountIds.contains(userId.lowercased())
    }

    var isSaving: Bool { savingIntent != nil }

    /// Which way the in-flight publish is going for `userId`, or nil when the
    /// mutation in flight is for somebody else. The list screen mutates one row
    /// at a time, so the direction has to be matched to a person.
    func publishingDirection(for userId: String) -> Bool? {
        guard let savingIntent, savingIntent.id.lowercased() == userId.lowercased() else { return nil }
        return savingIntent.blocked
    }

    /// True once the list has loaded and the resolved target is in it.
    var targetIsBlocked: Bool {
        guard isLoaded, let targetId else { return false }
        return blockedAccountIds.contains(targetId.lowercased())
    }

    /// Mutations are refused until the live snapshot has arrived, and while an
    /// unconfirmed publication is pending a different change would hide it.
    var canMutate: Bool {
        isLoaded && !isSaving && uncertainIntent == nil
    }

    func run(using appState: AppState, target: String?) async {
        let owner = UUID()
        lifetime = owner
        revision = nil
        guard appState.canUseRuntimeForForegroundWork, let account = appState.activeAccountRef else {
            isLoaded = false
            targetId = nil
            resolvedTargetReference = nil
            return
        }
        if ownerAccount != account || resolvedTargetReference != target {
            isLoaded = false
            targetId = nil
            resolvedTargetReference = nil
        }
        if ownerAccount != account {
            users = []
            uncertainIntent = nil
            error = nil
            ownerAccount = account
        }
        do {
            let client = try appState.currentMarmotClient()
            if let target {
                guard let resolved = await Task.detached(priority: .utility, operation: {
                    client.marmot.accountIdHex(reference: target)
                }).value else { throw MarmotKitError.InvalidIdentity(details: "Invalid profile reference.") }
                targetId = resolved
                resolvedTargetReference = target
            }
            let subscription = try await Task.detached(priority: .utility) {
                try client.marmot.subscribeBlockedUsers(accountRef: account)
            }.value
            guard !Task.isCancelled, lifetime == owner else { return }
            if let initial = await Task.detached(priority: .utility, operation: { subscription.snapshot() }).value {
                guard !Task.isCancelled, lifetime == owner, appState.activeAccountRef == account else { return }
                install(initial)
            }
            while let snapshot = try await subscription.nextCancellable() {
                guard !Task.isCancelled, lifetime == owner, appState.activeAccountRef == account else { return }
                install(snapshot)
            }
            if !Task.isCancelled, lifetime == owner { isLoaded = false }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, lifetime == owner else { return }
            isLoaded = false
            self.error = UserFacingError.message(for: error)
        }
    }

    private func install(_ snapshot: BlockListSnapshotFfi) {
        guard revision == nil || snapshot.revision > revision! else { return }
        revision = snapshot.revision
        users = snapshot.users
        isLoaded = true
        if uncertainIntent == nil { error = nil }
    }

    func setBlocked(_ blocked: Bool, userId: String, using appState: AppState) async {
        guard !isSaving, isLoaded, let account = appState.activeAccountRef else { return }
        if let intent = uncertainIntent, intent.id != userId || intent.blocked != blocked { return }
        let owner = lifetime
        savingIntent = (userId, blocked)
        defer { savingIntent = nil }
        do {
            let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
            defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
            if blocked { try await lease.client.marmot.blockUser(accountRef: account, userAccountIdHex: userId) }
            else { try await lease.client.marmot.unblockUser(accountRef: account, userAccountIdHex: userId) }
            let beforeRead = revision
            let confirmed = try await Task.detached(priority: .utility) {
                try lease.client.marmot.getBlockedUsers(accountRef: account)
            }.value
            guard lifetime == owner, appState.activeAccountRef == account else { return }
            if revision == beforeRead { users = confirmed }
            uncertainIntent = nil
            error = nil
            Haptics.success()
            appState.scheduleAccountUnreadSummaryRefresh()
        } catch MarmotKitError.BlockPublicationUncertain {
            guard lifetime == owner, appState.activeAccountRef == account else { return }
            Haptics.error()
            uncertainIntent = (userId, blocked)
            error = L10n.string("The block-list update could not be confirmed. Retry the same change to check its status.")
        } catch {
            guard lifetime == owner, appState.activeAccountRef == account else { return }
            Haptics.error()
            self.error = UserFacingError.message(for: error)
        }
    }
}

/// Pure projections for the block surfaces: who may be blocked, and how the
/// live snapshot becomes a stable list of rows.
nonisolated enum BlockedUsersPresentation {
    struct Row: Identifiable, Equatable {
        let accountIdHex: String
        let displayName: String
        /// nil when the stored key isn't a valid 32-byte public key, which is
        /// the only case where the row can't offer a profile destination.
        let npub: String?

        var id: String { accountIdHex }
    }

    /// One row per distinct blocked key, ordered by display name so the list
    /// doesn't reshuffle when MDK republishes the same people in a new order.
    /// MDK can list the same key twice (a private and a public entry); rows are
    /// deduplicated so identity stays the row's identity.
    static func rows(
        users: [BlockedUserFfi],
        displayName: (String) -> String,
        npub: (String) -> String?
    ) -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for user in users {
            let accountIdHex = user.publicKey.lowercased()
            guard seen.insert(accountIdHex).inserted else { continue }
            rows.append(
                Row(
                    accountIdHex: accountIdHex,
                    displayName: displayName(accountIdHex),
                    npub: npub(accountIdHex)
                )
            )
        }
        return rows.sorted {
            let byName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.accountIdHex < $1.accountIdHex
        }
    }

    /// Blocking is offered for a resolved identity that isn't one of this
    /// device's own signed-in profiles. Blocking yourself would hide your own
    /// messages, and an unresolved reference has no key to publish.
    static func canBlock(targetAccountIdHex: String?, localAccountIdHexes: [String]) -> Bool {
        guard let target = targetAccountIdHex?.lowercased(), !target.isEmpty else { return false }
        return !localAccountIdHexes.contains { $0.lowercased() == target }
    }

    /// A direct chat with a blocked peer says so in place of their last
    /// message. The inbox preview is the one place their words would still
    /// reach the screen after the conversation itself stopped showing them.
    /// Group rows never qualify: a blocked member is one voice among many
    /// there, so the row still belongs to the group.
    static func showsBlockedPeerPreview(
        isDirectMessage: Bool?,
        directPeerAccountIdHex: String?,
        blockedAccountIds: Set<String>
    ) -> Bool {
        guard isDirectMessage == true,
              let peer = directPeerAccountIdHex?.lowercased(),
              !peer.isEmpty
        else { return false }
        return blockedAccountIds.contains(peer)
    }

    /// What a surface about one person shows for its block control.
    enum BlockAction: Equatable {
        /// On screen but not actionable: the live list hasn't arrived, the
        /// reference hasn't resolved, or an unconfirmed publication is holding
        /// the surface. Never absent — hiding it leaves no affordance at all
        /// when a read is slow or the runtime is suspended.
        case inert(isBlocked: Bool)
        case ready(isBlocked: Bool)
        /// A tapped mutation is publishing. The surface names the direction
        /// rather than greying out with no explanation.
        case publishing(isBlocking: Bool)
    }

    static func blockAction(
        isLoaded: Bool,
        publishingIsBlocking: Bool?,
        hasUncertainIntent: Bool,
        isBlocked: Bool,
        targetAccountIdHex: String?
    ) -> BlockAction {
        if let publishingIsBlocking {
            return .publishing(isBlocking: publishingIsBlocking)
        }
        guard let target = targetAccountIdHex, !target.isEmpty, isLoaded, !hasUncertainIntent else {
            return .inert(isBlocked: isBlocked)
        }
        return .ready(isBlocked: isBlocked)
    }
}

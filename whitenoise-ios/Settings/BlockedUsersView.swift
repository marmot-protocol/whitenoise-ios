import SwiftUI
import MarmotKit

@MainActor
@Observable
final class BlockedUsersModel {
    private(set) var users: [BlockedUserFfi] = []
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var targetId: String?
    private(set) var uncertainIntent: (id: String, blocked: Bool)?
    @ObservationIgnored private var lifetime = UUID()
    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var ownerAccount: String?

    func isConfirmedBlocked(_ userId: String, accountRef: String?) -> Bool {
        isLoaded && ownerAccount == accountRef && users.contains { $0.publicKey == userId }
    }

    func run(using appState: AppState, target: String?) async {
        let owner = UUID()
        lifetime = owner
        isLoaded = false
        revision = nil
        targetId = nil
        guard appState.canUseRuntimeForForegroundWork, let account = appState.activeAccountRef else { return }
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
        isSaving = true
        defer { isSaving = false }
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
            appState.scheduleAccountUnreadSummaryRefresh()
        } catch MarmotKitError.BlockPublicationUncertain {
            guard lifetime == owner, appState.activeAccountRef == account else { return }
            uncertainIntent = (userId, blocked)
            error = L10n.string("The block-list update could not be confirmed. Retry the same change to check its status.")
        } catch {
            guard lifetime == owner, appState.activeAccountRef == account else { return }
            self.error = UserFacingError.message(for: error)
        }
    }
}

struct BlockedUsersView: View {
    @Environment(AppState.self) private var appState
    var userReference: String? = nil
    @State private var model = BlockedUsersModel()
    @State private var reload = 0
    @State private var confirmingBlock = false

    private var subscriptionKey: String {
        "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseRuntimeForForegroundWork)/\(reload)"
    }

    var body: some View {
        List {
            if !model.isLoaded {
                Section {
                    if model.error == nil { ProgressView("Loading…") }
                    Button("Retry") { reload += 1 }
                }
            } else if let id = model.targetId {
                Section {
                    Text(appState.displayName(forAccountIdHex: id))
                    let blocked = model.users.contains { $0.publicKey == id }
                    Button(blocked ? "Unblock User" : "Block User", role: blocked ? nil : .destructive) {
                        if blocked { Task { await model.setBlocked(false, userId: id, using: appState) } }
                        else { confirmingBlock = true }
                    }
                    .disabled(model.isSaving || model.uncertainIntent != nil)
                } footer: {
                    Text("Blocking hides this person’s messages and prevents sending to them in direct chats. Existing history is retained.")
                }
            } else {
                Section {
                    if model.users.isEmpty { Text("No blocked users") }
                    ForEach(model.users, id: \.publicKey) { user in
                        HStack {
                            Text(appState.displayName(forAccountIdHex: user.publicKey))
                            Spacer()
                            Button("Unblock") {
                                Task { await model.setBlocked(false, userId: user.publicKey, using: appState) }
                            }
                            .disabled(model.isSaving || model.uncertainIntent != nil)
                        }
                    }
                }
            }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    if let intent = model.uncertainIntent {
                        Button("Retry") { Task { await model.setBlocked(intent.blocked, userId: intent.id, using: appState) } }
                            .disabled(model.isSaving)
                    }
                }
            }
        }
        .navigationTitle("Blocked Users")
        .task(id: subscriptionKey) { await model.run(using: appState, target: userReference) }
        .confirmationDialog("Block this user?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button("Block User", role: .destructive) {
                if let id = model.targetId { Task { await model.setBlocked(true, userId: id, using: appState) } }
            }
        }
    }
}

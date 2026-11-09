import Foundation
import MarmotKit

@MainActor @Observable
final class GroupRecoveryModel {
    private(set) var status: GroupRecoveryStatusFfi?
    private(set) var isBusy = false
    var errorMessage: String?
    /// MDK stopped retrying this chat's sync after repeated failures; sends
    /// stay queued until it resumes.
    private(set) var syncParked = false
    private(set) var isRetryingSync = false
    private(set) var syncRetryError: String?
    private var generation = UUID()
    private var readTicket = UUID()
    private var accountRef: String?
    private var runtimeGeneration: Int?

    func invalidate() {
        generation = UUID()
        readTicket = UUID()
        status = nil
        accountRef = nil
        runtimeGeneration = nil
        isBusy = false
        errorMessage = nil
        syncParked = false
        isRetryingSync = false
        syncRetryError = nil
    }

    func refresh(using appState: AppState, groupID: String) async {
        guard !Task.isCancelled, appState.canUseRuntimeForForegroundWork, let account = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else { return }
        if accountRef != account || runtimeGeneration != appState.runtimeGeneration {
            invalidate()
            accountRef = account
            runtimeGeneration = appState.runtimeGeneration
        }
        let context = generation
        let ticket = UUID()
        readTicket = ticket
        let recovery: Result<GroupRecoveryStatusFfi, Error>
        do {
            recovery = .success(try await client.groupRecoveryStatus(accountRef: account, groupIdHex: groupID))
        } catch {
            recovery = .failure(error)
        }
        // A failed read keeps the last answer; the next group-state event re-reads it.
        let parked = try? await client.groupMlsState(accountRef: account, groupIdHex: groupID).convergenceParked
        guard !Task.isCancelled, generation == context, readTicket == ticket, matches(appState) else { return }
        if let parked {
            syncParked = parked
            if !parked { syncRetryError = nil }
        }
        switch recovery {
        case .success(let next):
            guard next.groupIdHex == groupID else { return }
            status = next
            errorMessage = nil
        case .failure:
            // Keep an existing offer for inspection, but let MDK revalidate every decision.
            errorMessage = L10n.string("Couldn’t check group recovery. Try again.")
        }
    }

    /// Grants MDK one more sync attempt for a parked chat, then re-reads.
    func retrySync(using appState: AppState, groupID: String) async {
        guard !isRetryingSync, matches(appState), let accountRef else { return }
        let context = generation
        isRetryingSync = true
        syncRetryError = nil
        readTicket = UUID()
        defer { if generation == context { isRetryingSync = false } }
        do {
            let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
            defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
            _ = try await lease.client.retryGroupConvergence(accountRef: accountRef, groupIdHex: groupID)
        } catch {
            guard generation == context, matches(appState) else { return }
            syncRetryError = UserFacingError.message(
                for: error, fallbackMessage: L10n.string("Couldn’t retry syncing. Try again.")
            )
        }
        guard generation == context, matches(appState) else { return }
        await refresh(using: appState, groupID: groupID)
    }

    func decide(_ offer: GroupRejoinInvitationFfi, confirm: Bool, using appState: AppState) async -> Bool {
        guard !isBusy, matches(appState), let accountRef,
              let status, Self.containsDisplayedOffer(offer, in: status) else { return false }
        let context = generation
        isBusy = true
        readTicket = UUID()
        errorMessage = nil
        defer { if generation == context { isBusy = false } }
        do {
            let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
            defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
            if confirm {
                let next = try await lease.client.confirmGroupRejoin(accountRef: accountRef, offer: offer)
                guard generation == context, matches(appState) else { return false }
                readTicket = UUID()
                self.status = next
            } else {
                try await lease.client.declineGroupRejoin(accountRef: accountRef, welcomeIdHex: offer.welcomeIdHex)
                guard generation == context, matches(appState) else { return false }
                readTicket = UUID()
                self.status?.rejoinInvitations.removeAll { $0.welcomeIdHex == offer.welcomeIdHex }
            }
            return true
        } catch {
            guard generation == context, matches(appState) else { return false }
            await refresh(using: appState, groupID: status.groupIdHex)
            guard generation == context, matches(appState) else { return false }
            errorMessage = L10n.string("Couldn’t apply this invitation. Review the latest offer and try again.")
            return false
        }
    }

    private func matches(_ appState: AppState) -> Bool {
        appState.canUseRuntimeForForegroundWork && appState.activeAccountRef == accountRef
            && appState.runtimeGeneration == runtimeGeneration
    }

    /// Whether the recovery area has anything to show, so it takes no space otherwise.
    static func hasContent(status: GroupRecoveryStatusFfi?, errorMessage: String?, syncParked: Bool) -> Bool {
        guard errorMessage == nil, !syncParked else { return true }
        guard let status else { return false }
        return !status.rejoinInvitations.isEmpty || status.automaticRecoveryFailed || status.historyMayBeIncomplete
            || status.pendingReinvites > 0 || status.failedReinvites > 0
    }

    static func containsDisplayedOffer(_ offer: GroupRejoinInvitationFfi, in status: GroupRecoveryStatusFfi) -> Bool {
        status.rejoinInvitations.contains {
            $0.welcomeIdHex == offer.welcomeIdHex && $0.localStateToken == offer.localStateToken
                && $0.welcomerAccountIdHex == offer.welcomerAccountIdHex && $0.epoch == offer.epoch
        }
    }
}

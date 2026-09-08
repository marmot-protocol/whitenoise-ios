import Foundation
import MarmotKit

@MainActor @Observable
final class GroupRecoveryModel {
    private(set) var status: GroupRecoveryStatusFfi?
    private(set) var isBusy = false
    var errorMessage: String?
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
        do {
            let next = try await client.groupRecoveryStatus(accountRef: account, groupIdHex: groupID)
            guard !Task.isCancelled, generation == context, readTicket == ticket,
                  matches(appState), next.groupIdHex == groupID else { return }
            status = next
            errorMessage = nil
        } catch {
            // Keep an existing offer for inspection, but let MDK revalidate every decision.
            guard generation == context, readTicket == ticket, matches(appState) else { return }
            errorMessage = L10n.string("Couldn’t check group recovery. Try again.")
        }
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

    static func containsDisplayedOffer(_ offer: GroupRejoinInvitationFfi, in status: GroupRecoveryStatusFfi) -> Bool {
        status.rejoinInvitations.contains {
            $0.welcomeIdHex == offer.welcomeIdHex && $0.localStateToken == offer.localStateToken
                && $0.welcomerAccountIdHex == offer.welcomerAccountIdHex && $0.epoch == offer.epoch
        }
    }
}

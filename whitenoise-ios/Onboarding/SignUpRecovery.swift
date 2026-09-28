import Foundation
import MarmotKit

extension AppState {
    func restoreSignUpIfNeeded(accounts: [AccountSummaryFfi], client: MarmotClient) async throws {
        guard !hasRestoredSignUp else { return }
        if let task = signUpRestorationTask { return try await task.value }
        let task = Task { try await restoreSignUp(accounts: accounts, client: client) }
        signUpRestorationTask = task
        defer { signUpRestorationTask = nil }
        try await task.value
    }

    private func restoreSignUp(accounts: [AccountSummaryFfi], client: MarmotClient) async throws {
        var saved: SignUpDraft?
        do {
            saved = try await signUpDraftStore.load()
            try Task.checkCancellation()
            guard self.client === client else { throw CancellationError() }
            guard var draft = saved else {
                await signUpModel.configurePersistence(store: signUpDraftStore)
                hasRestoredSignUp = true
                return
            }
            let identity = try draft.recoveredAccount(in: accounts)
            let profile: UserProfileMetadataFfi?
            if let identity, draft.stage != .resetting {
                draft.accountID = identity.accountIdHex
                draft.accountRef = identity.label
                profile = try await client.userProfileForEditing(accountIdHex: identity.accountIdHex)
                let readiness = try await client.accountSetupReadiness(accountRef: identity.label)
                try Task.checkCancellation()
                guard self.client === client else { throw CancellationError() }
                if readiness == .networkReady,
                   draft.stage == .completed || (draft.stage == .publishing && profile.map(draft.matchesPublishedProfile) == true) {
                    // Publication can finish just before the host records completion.
                    activeAccountRef = identity.label
                    try await signUpDraftStore.clear(id: draft.id)
                    await signUpModel.configurePersistence(store: signUpDraftStore)
                    hasRestoredSignUp = true
                    return
                }
            } else {
                profile = nil
            }
            draft.revision += 1
            try await signUpDraftStore.save(draft)
            await signUpModel.configurePersistence(store: signUpDraftStore, restored: draft, identity: identity, profile: profile)
            restoreSignUpPresentation = true
            hasRestoredSignUp = true
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MarmotKitError where error.isTransientStartupReadinessFailure {
            throw error
        } catch {
            try Task.checkCancellation()
            guard self.client === client else { throw CancellationError() }
            await signUpModel.configureRestorationFailure(store: signUpDraftStore, restored: saved)
            restoreSignUpPresentation = true
            hasRestoredSignUp = true
        }
    }

    func retrySignUpRestoration() async {
        guard signUpModel.isRestorationBlocked, signUpRestorationTask == nil else { return }
        let previousModel = signUpModel
        signUpModel = CreateIdentityViewModel()
        hasRestoredSignUp = false
        do {
            try await refreshAccounts(refreshUnreadSummaries: false)
        } catch {
            signUpModel = previousModel
            hasRestoredSignUp = true
        }
    }

    func isUnfinishedSignUpAccount(_ accountID: String) -> Bool {
        guard !signUpModel.isFinished else { return false }
        return signUpModel.createdIdentity?.accountIdHex == accountID
            || signUpModel.draft.blocksActivation(accountID: accountID)
    }

    func openSignUpDraft() async {
        if signUpModel.isFinished {
            signUpModel = CreateIdentityViewModel()
        }
        await signUpModel.configurePersistence(store: signUpDraftStore)
        await signUpModel.persistDraft()
    }

    func closeSignUpDraft() {
        let model = signUpModel
        guard !model.isSubmitting, !model.isResetting else { return }
        if model.isFinished || (!model.draft.requiresRecovery && !model.isRestorationBlocked) {
            signUpModel = CreateIdentityViewModel()
        }
    }
}

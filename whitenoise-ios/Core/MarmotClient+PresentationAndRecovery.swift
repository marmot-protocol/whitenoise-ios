import MarmotKit

extension MarmotClient {
    func approveOnboarding(accountID: String, revision: UInt64, recoveryEpoch: String?) async throws -> OnboardingSnapshotFfi {
        if let recoveryEpoch {
            return try await marmot.approveOnboardingRepairInEpoch(
                accountRef: accountID, revision: revision, recoveryEpoch: recoveryEpoch
            )
        }
        return try await marmot.approveOnboardingRepair(accountRef: accountID, revision: revision)
    }

    func acknowledgeOnboarding(accountID: String, revision: UInt64, recoveryEpoch: String?) async throws -> OnboardingSnapshotFfi {
        if let recoveryEpoch {
            return try await marmot.acknowledgeOnboardingSingleDeviceInEpoch(
                accountRef: accountID, revision: revision, recoveryEpoch: recoveryEpoch
            )
        }
        return try await marmot.acknowledgeOnboardingSingleDevice(accountRef: accountID, revision: revision)
    }

    func onboardingRecoveryRequired(accountRef: String) async throws -> Bool {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.onboardingRecoveryRequired(accountRef: accountRef)
        }.value
    }

    func recoverOnboarding(accountRef: String) async throws -> String {
        try await marmot.recoverOnboarding(accountRef: accountRef, acknowledgeLatestOnlyEvidence: true)
    }

    func groupRecoveryStatus(accountRef: String, groupIdHex: String) async throws -> GroupRecoveryStatusFfi {
        try await marmot.groupRecoveryStatus(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func confirmGroupRejoin(accountRef: String, offer: GroupRejoinInvitationFfi) async throws -> GroupRecoveryStatusFfi {
        try await marmot.confirmGroupRejoin(
            accountRef: accountRef, welcomeIdHex: offer.welcomeIdHex, localStateToken: offer.localStateToken
        )
    }

    func declineGroupRejoin(accountRef: String, welcomeIdHex: String) async throws {
        try await marmot.declineGroupRejoin(accountRef: accountRef, welcomeIdHex: welcomeIdHex)
    }

    func presentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSnapshotFfi {
        try await marmot.presentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListRow(accountRef: String, groupIdHex: String) async throws -> PresentedChatRowFfi? {
        try await marmot.presentedChatListRow(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func openPresentedChatList(accountRef: String, includeArchived: Bool) async throws -> PresentedChatListSubscription {
        try await marmot.openPresentedChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func presentedChatListSubscriptionSnapshot(_ subscription: PresentedChatListSubscription) async -> PresentedChatListUpdateFfi? {
        await Task.detached(priority: .utility) { subscription.snapshot() }.value
    }
}

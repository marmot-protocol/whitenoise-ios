import MarmotKit
@testable import whitenoise_ios

/// Lets a test pause or fail `refreshAccounts`' reads after its app state
/// exists. Each read runs the live call once its `before` handler returns; the
/// app state keeps the stub alive, so a handler can't be dropped mid-test.
@MainActor
final class AccountRefreshReadsStub {
    var beforeListAccounts: (@MainActor () async throws -> Void)?
    var beforeOnboardingSnapshot: (@MainActor (_ accountID: String) async throws -> Void)?

    var reads: AccountRefreshReads {
        AccountRefreshReads(
            listAccounts: { client in
                try await self.beforeListAccounts?()
                return try await AccountRefreshReads.live.listAccounts(client)
            },
            onboardingSnapshot: { client, accountID in
                try await self.beforeOnboardingSnapshot?(accountID)
                return try await AccountRefreshReads.live.onboardingSnapshot(client, accountID)
            }
        )
    }
}

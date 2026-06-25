import Testing
@testable import whitenoise_ios
@testable import MarmotKit

/// #51 — listAccounts is now an async method on MarmotClient that encapsulates
/// the off-main-actor offload, so callers use a plain await with no Task.detached.
@MainActor
struct MarmotClientListAccountsTests {

    @Test func listAccountsReturnsEmptyForFreshClient() async throws {
        let client = try MarmotClient.testClient()
        let accounts = try await client.listAccounts()
        #expect(accounts.isEmpty)
    }
}

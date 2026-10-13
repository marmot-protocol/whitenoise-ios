import Foundation
import MarmotKit
import Testing
import UserNotifications
@testable import whitenoise_ios

@MainActor
struct OnboardingRecoveryRemovalTests {
    @Test func removingBrokenSetupRemovesOnlySelectedProfileAndSurvivesRefresh() async throws {
        let (state, client) = try await makeState()
        do {
            let removed = try await makeBrokenAccount(client)
            let retained = try await makeBrokenAccount(client, nsec: "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn")
            try await state.refreshAccounts(refreshUnreadSummaries: false)
            #expect(state.onboardingRecoveryAccounts.count == 2)

            try await state.removeOnboardingRecoveryAccount(removed)

            #expect(try await client.listAccounts().map(\.accountIdHex) == [retained.accountIdHex])
            #expect(state.onboardingRecoveryAccounts.map(\.accountIdHex) == [retained.accountIdHex])
            #expect(!FileManager.default.fileExists(atPath: accountDirectory(removed, client).path))
            #expect(try await client.onboardingRecoveryRequired(accountRef: retained.label))
            try await state.refreshAccounts(refreshUnreadSummaries: false)
            #expect(state.onboardingRecoveryAccounts.map(\.accountIdHex) == [retained.accountIdHex])
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
        try await client.marmot.shutdownAndClose()
    }

    @Test func staleRecoverySelectionCannotRemoveARepairedProfile() async throws {
        let (state, client) = try await makeState()
        do {
            let account = try await makeBrokenAccount(client)
            try await state.refreshAccounts(refreshUnreadSummaries: false)
            #expect(state.onboardingRecoveryAccounts.count == 1)
            try FileManager.default.removeItem(at: accountDirectory(account, client).appendingPathComponent("onboarding.json"))
            #expect(try await !client.onboardingRecoveryRequired(accountRef: account.label))

            await #expect(throws: MarmotKitError.OnboardingActionUnavailable) {
                try await state.removeOnboardingRecoveryAccount(account)
            }
            #expect(try await client.listAccounts().map(\.accountIdHex) == [account.accountIdHex])
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
        try await client.marmot.shutdownAndClose()
    }

    @Test func recoveryKeepsProfileButClearsTheRecoveryEntryWithoutStartingSignIn() async throws {
        let (state, client) = try await makeState()
        do {
            let account = try await makeBrokenAccount(client)
            try await state.refreshAccounts(refreshUnreadSummaries: false)
            try await state.recoverOnboardingSetup(accountID: account.accountIdHex)
            #expect(state.onboardingRecoveryAccounts.isEmpty)
            let retained = try #require(try await client.listAccounts().first)
            #expect(retained.accountIdHex == account.accountIdHex)
            #expect(retained.signedOut)
            #expect(state.pendingAccountSetup == nil)
            #expect(state.activeAccountRef == nil)
            #expect(try await !client.onboardingRecoveryRequired(accountRef: account.label))
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
        try await client.marmot.shutdownAndClose()
    }

    @Test func successfulRecoveryStaysSuccessfulWhenAccountRefreshFails() async throws {
        let (state, client) = try await makeState()
        do {
            let account = try await makeBrokenAccount(client)
            try await state.refreshAccounts(refreshUnreadSummaries: false)
            state.beforeAccountRefreshForTesting = { throw URLError(.notConnectedToInternet) }

            try await state.recoverOnboardingSetup(accountID: account.accountIdHex)

            #expect(state.onboardingRecoveryAccounts.isEmpty)
            #expect(try await !client.onboardingRecoveryRequired(accountRef: account.label))
            let retained = try #require(try await client.listAccounts().first)
            #expect(retained.signedOut)
            #expect(state.pendingAccountSetup == nil)
            #expect(state.activeAccountRef == nil)
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
        try await client.marmot.shutdownAndClose()
    }

    private func makeState() async throws -> (AppState, MarmotClient) {
        let client = try MarmotClient.testClient()
        let state = AppState.test(
            client: client,
            notifications: AppNotifications(
                requestAuthorizationHandler: { false },
                authorizationStatusProvider: { .denied },
                remoteNotificationRegistrar: {}
            ),
            accountDefaults: IsolatedAccountDefaults.make()
        )
        state.setAppSceneActive(true)
        await state.bootstrap()
        return (state, client)
    }

    private func makeBrokenAccount(
        _ client: MarmotClient,
        nsec: String = "nsec1j4c6269y9w0q2er2xjw8sv2ehyrtfxq3jwgdlxj6qfn8z4gjsq5qfvfk99"
    ) async throws -> AccountSummaryFfi {
        let snapshot = try await client.marmot.beginOnboarding(
            nsec: nsec,
            options: OnboardingOptionsFfi(defaultRelays: client.relayUrls, discoveryRelays: client.relayUrls)
        )
        try await client.marmot.cancelOnboarding(accountRef: snapshot.accountIdHex)
        let account = try #require(try await client.listAccounts().first { $0.accountIdHex == snapshot.accountIdHex })
        // Exercise the SDK's actual unreadable-checkpoint gate and deletion path.
        try Data("invalid checkpoint".utf8).write(to: accountDirectory(account, client).appendingPathComponent("onboarding.json"))
        return account
    }

    private func accountDirectory(_ account: AccountSummaryFfi, _ client: MarmotClient) -> URL {
        URL(fileURLWithPath: client.rootPath).appendingPathComponent("accounts").appendingPathComponent(account.label)
    }
}

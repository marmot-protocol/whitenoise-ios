import Foundation
import MarmotKit
import Testing
import UserNotifications

@testable import whitenoise_ios

@MainActor
struct IdentityImportRuntimeTests {
    private let accountDefaults = IsolatedAccountDefaults.make()

    @Test func userInitiatedMutationJoinsForegroundRuntimeRebuild() async throws {
        let appState = AppState.test(
            client: try MarmotClient.testClient(),
            notifications: AppNotifications(
                requestAuthorizationHandler: { false },
                authorizationStatusProvider: { .denied },
                remoteNotificationRegistrar: {}
            ),
            accountDefaults: accountDefaults
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)

        let lease = try await appState.runtimeLifecycle.beginUserInitiatedForegroundRuntimeMutation()

        #expect(lease.client === appState.client)
        #expect(appState.client != nil)
        #expect(!appState.runtimeSuspendedForBackground)
        appState.runtimeLifecycle.endForegroundRuntimeMutation(lease)

        await appState.startRuntimeSuspension().value
    }
}

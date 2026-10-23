import Foundation
import ObjectiveC
@testable import whitenoise_ios

extension AppState {
    /// Test instance with isolated host state. Unless a test passes its own:
    /// - account and preference defaults share one uniquely named suite, and
    ///   erasure recovery gets a second one;
    /// - conversation and sign-up drafts live in temporary directories;
    /// - notifications go through a fresh `AppNotifications` instead of
    ///   `.shared`.
    /// The suites and directories are removed when the state is released.
    ///
    /// Not isolated:
    /// - the fresh `AppNotifications` still talks to the system
    ///   `UNUserNotificationCenter` unless a test injects handlers;
    /// - without a `client`, `bootstrap()` builds its runtime through
    ///   `runtimeClientFactory`, which defaults to
    ///   `AppContainerConfig.productionMarmotRoot()`;
    /// - `eraseAppData` still clears `UserDefaults.standard`, the app group
    ///   suite and the process-wide media/link stores;
    /// - runtime retries use the production backoff. Pass
    ///   `runtimeRetrySleeper: AppStateTestResources.immediateRetry` only
    ///   when the test does not exercise ownership contention or
    ///   background/resume timing.
    static func test(
        client: MarmotClient? = nil,
        notifications: AppNotifications? = nil,
        conversationDraftStore: ConversationDraftStore? = nil,
        signUpDraftStore: SignUpDraftStore? = nil,
        accountDefaults: UserDefaults? = nil,
        erasureDefaults: UserDefaults? = nil,
        preferenceDefaults: UserDefaults? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = TelemetryBuildConfig.current(),
        runtimeClientFactory: @escaping RuntimeLifecycle.RuntimeClientFactory = RuntimeLifecycle.defaultRuntimeClientFactory,
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = { delay in try await Task.sleep(for: delay) },
        runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy = .foreground
    ) -> AppState {
        let resources = AppStateTestResources()
        let isolatedDefaults = accountDefaults ?? resources.makeDefaults("AppStateTest")
        let state = AppState(
            client: client,
            notifications: notifications ?? AppNotifications(),
            conversationDraftStore: conversationDraftStore ?? ConversationDraftStore(
                legacyFileURL: resources.makeDirectory("ConversationDraftTests")
                    .appendingPathComponent("conversation-drafts.json", isDirectory: false)
            ),
            signUpDraftStore: signUpDraftStore ?? SignUpDraftStore(
                directory: resources.makeDirectory("SignUpDraftTests")
            ),
            accountDefaults: isolatedDefaults,
            erasureDefaults: erasureDefaults ?? resources.makeDefaults("AppStateTestErasure"),
            preferenceDefaults: preferenceDefaults ?? isolatedDefaults,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig,
            runtimeClientFactory: runtimeClientFactory,
            runtimeRetrySleeper: runtimeRetrySleeper,
            runtimeConstructionRetryPolicy: runtimeConstructionRetryPolicy
        )
        objc_setAssociatedObject(state, &AppStateTestResources.key, resources, .OBJC_ASSOCIATION_RETAIN)
        return state
    }
}

/// Owns the isolated defaults suites and directories of one `AppState.test()`
/// instance and removes them when that instance is deallocated.
final class AppStateTestResources: @unchecked Sendable {
    nonisolated(unsafe) static var key: UInt8 = 0

    /// Opt-in retry sleeper that skips the backoff delay.
    static let immediateRetry: RuntimeLifecycle.RetrySleeper = { _ in
        try Task.checkCancellation()
        await Task.yield()
    }

    private var suiteNames: [String] = []
    private var directories: [URL] = []

    func makeDefaults(_ prefix: String) -> UserDefaults {
        let name = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Cannot open test defaults suite \(name)")
        }
        suiteNames.append(name)
        return defaults
    }

    func makeDirectory(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        directories.append(url)
        return url
    }

    deinit {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        for url in directories {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

import Foundation
import ObjectiveC
@testable import whitenoise_ios

extension AppState {
    /// Hermetic test instance. Unless a test passes its own, every store is
    /// isolated: account and preference defaults share one unique suite,
    /// erasure recovery gets another, drafts live in a temporary directory,
    /// notifications use a fresh `AppNotifications` instead of `.shared`, and
    /// runtime retries do not wait. Everything is removed when the state is
    /// released.
    @MainActor
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
        runtimeRetrySleeper: @escaping RuntimeLifecycle.RetrySleeper = AppStateTestResources.immediateRetry,
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
final class AppStateTestResources {
    nonisolated(unsafe) static var key: UInt8 = 0

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

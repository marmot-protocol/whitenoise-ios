import Foundation

/// Decides whether the app scene should bring up the production Marmot
/// runtime at launch. While the app is only hosting a unit-test bundle it
/// must not, otherwise a production-root runtime boots in the test process and
/// competes with the temp-directory runtimes the tests create. A test that
/// deliberately needs the real launch path opts back in with
/// `WN_TEST_HOST_BOOTSTRAP=1` in the test host's environment.
nonisolated enum AppLaunchPolicy {
    static let testHostBootstrapOverrideKey = "WN_TEST_HOST_BOOTSTRAP"

    static func shouldStartRuntime(
        isUnitTestHost: Bool,
        overrideEnvironment: [String: String]
    ) -> Bool {
        guard isUnitTestHost else { return true }
        return overrideEnvironment[testHostBootstrapOverrideKey] == "1"
    }

    static func shouldStartRuntime(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        shouldStartRuntime(
            isUnitTestHost: ProcessEnvironment.isUnitTestHost(environment),
            overrideEnvironment: environment
        )
    }
}

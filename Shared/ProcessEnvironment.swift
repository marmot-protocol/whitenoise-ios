import Foundation

/// Process-level facts read from the environment. Extension-safe: Foundation
/// only, so the Notification Service Extension can compile it too.
nonisolated enum ProcessEnvironment {
    /// Set by Xcode/XCTest in the process that hosts a unit-test bundle.
    static let unitTestConfigurationKey = "XCTestConfigurationFilePath"

    /// Environment-only so launch decisions stay pure and testable.
    /// `AppLanguage.testDefaults` additionally checks for a loaded `XCTestCase`
    /// class because its lazy read may run in a test process whose runner does
    /// not export the variable; `AppLaunchPolicyTests` has a live canary that
    /// fails if the host stops exporting it.
    static func isUnitTestHost(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[unitTestConfigurationKey] != nil
    }
}

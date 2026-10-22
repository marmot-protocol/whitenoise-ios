import Foundation

/// Process-level facts read from the environment. Extension-safe: Foundation
/// only, so the Notification Service Extension can compile it too.
nonisolated enum ProcessEnvironment {
    /// Set by Xcode/XCTest in the process that hosts a unit-test bundle.
    static let unitTestConfigurationKey = "XCTestConfigurationFilePath"

    static func isUnitTestHost(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[unitTestConfigurationKey] != nil
    }
}

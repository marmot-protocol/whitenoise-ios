import Testing
@testable import whitenoise_ios

nonisolated struct AppLaunchPolicyTests {
    @Test func startsOutsideUnitTestHost() {
        #expect(AppLaunchPolicy.shouldStartRuntime(isUnitTestHost: false, overrideEnvironment: [:]))
        #expect(AppLaunchPolicy.shouldStartRuntime(environment: ["PATH": "/usr/bin"]))
    }

    @Test func skipsUnitTestHost() {
        #expect(!AppLaunchPolicy.shouldStartRuntime(isUnitTestHost: true, overrideEnvironment: [:]))
        #expect(!AppLaunchPolicy.shouldStartRuntime(
            environment: [ProcessEnvironment.unitTestConfigurationKey: "/tmp/config.xctestconfiguration"]
        ))
    }

    @Test func overrideRequestsRealLaunchInUnitTestHost() {
        let override = [AppLaunchPolicy.testHostBootstrapOverrideKey: "1"]
        #expect(AppLaunchPolicy.shouldStartRuntime(isUnitTestHost: true, overrideEnvironment: override))
        #expect(!AppLaunchPolicy.shouldStartRuntime(
            isUnitTestHost: true,
            overrideEnvironment: [AppLaunchPolicy.testHostBootstrapOverrideKey: "0"]
        ))
        #expect(AppLaunchPolicy.shouldStartRuntime(
            environment: [
                ProcessEnvironment.unitTestConfigurationKey: "/tmp/config.xctestconfiguration",
                AppLaunchPolicy.testHostBootstrapOverrideKey: "1"
            ]
        ))
    }

    @Test func unitTestHostDetectionReadsXCTestConfigurationKey() {
        #expect(!ProcessEnvironment.isUnitTestHost([:]))
        #expect(ProcessEnvironment.isUnitTestHost([ProcessEnvironment.unitTestConfigurationKey: ""]))
    }
}

import Testing
@testable import whitenoise_ios

nonisolated struct ProcessEnvironmentTests {
    @Test func unitTestHostDetectionReadsXCTestConfigurationKey() {
        #expect(!ProcessEnvironment.isUnitTestHost([:]))
        #expect(!ProcessEnvironment.isUnitTestHost(["PATH": "/usr/bin"]))
        #expect(ProcessEnvironment.isUnitTestHost([ProcessEnvironment.unitTestConfigurationKey: ""]))
    }

    /// Live canary: the test-host guard in `whitenoise_iosApp` rests on the
    /// runner exporting this variable to the host. If a future Xcode stops,
    /// the host would boot the production runtime again with nothing else
    /// failing.
    @Test func runnerExportsUnitTestHostMarkerToThisProcess() {
        #expect(ProcessEnvironment.isUnitTestHost())
    }
}

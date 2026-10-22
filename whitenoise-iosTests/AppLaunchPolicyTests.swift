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
        let override = [AppLaunchPolicy.hostBootstrapOverrideKey: "1"]
        #expect(AppLaunchPolicy.shouldStartRuntime(isUnitTestHost: true, overrideEnvironment: override))
        for spelling in ["0", "true", "YES", ""] {
            #expect(!AppLaunchPolicy.shouldStartRuntime(
                isUnitTestHost: true,
                overrideEnvironment: [AppLaunchPolicy.hostBootstrapOverrideKey: spelling]
            ))
        }
        #expect(AppLaunchPolicy.shouldStartRuntime(
            environment: [
                ProcessEnvironment.unitTestConfigurationKey: "/tmp/config.xctestconfiguration",
                AppLaunchPolicy.hostBootstrapOverrideKey: "1"
            ]
        ))
    }

    @Test func unitTestHostDetectionReadsXCTestConfigurationKey() {
        #expect(!ProcessEnvironment.isUnitTestHost([:]))
        #expect(ProcessEnvironment.isUnitTestHost([ProcessEnvironment.unitTestConfigurationKey: ""]))
    }

    /// Live canary: the whole guard rests on the runner exporting this
    /// variable to the host. If a future Xcode stops, the host would boot the
    /// production runtime again with nothing else failing.
    @Test func runnerExportsUnitTestHostMarkerToThisProcess() {
        #expect(ProcessEnvironment.isUnitTestHost())
    }

    @Test func sceneRuntimeStepSkipsRuntimeWorkInUnitTestHost() {
        #expect(SceneRuntimeStep.resolve(.activate, isInitial: true, startsRuntime: true) == .markSceneActive)
        #expect(SceneRuntimeStep.resolve(.activate, isInitial: false, startsRuntime: true) == .startForegroundActivation)
        #expect(SceneRuntimeStep.resolve(.remainInactive, isInitial: false, startsRuntime: true) == .markSceneInactive)
        #expect(SceneRuntimeStep.resolve(.suspend, isInitial: false, startsRuntime: true) == .suspendRuntime)
        #expect(SceneRuntimeStep.resolve(.activate, isInitial: false, startsRuntime: false) == .markSceneActive)
        #expect(SceneRuntimeStep.resolve(.suspend, isInitial: false, startsRuntime: false) == .markSceneInactive)
    }
}

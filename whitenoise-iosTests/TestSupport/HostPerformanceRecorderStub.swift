import MarmotKit
@testable import whitenoise_ios

/// Lets a test watch the runtime lifecycle's `host_*` stage timings after its
/// app state exists. Every timing still goes to the live recorder; the app
/// state keeps the stub alive, so a handler can't be dropped mid-test.
@MainActor
final class HostPerformanceRecorderStub {
    var onRecord: ((HostPerformanceOperationFfi, UInt64, HostPerformanceOutcomeFfi) -> Void)?

    var recorder: RuntimeLifecycle.HostPerformanceRecorder {
        { client, operation, durationMs, outcome in
            self.onRecord?(operation, durationMs, outcome)
            RuntimeLifecycle.recordHostPerformanceOnClient(client, operation, durationMs, outcome)
        }
    }
}

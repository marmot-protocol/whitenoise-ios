import Foundation
import Testing

actor AsyncTestGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int = 1) {
        availablePermits = permits
    }

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            availablePermits += 1
            return
        }
        waiters.removeFirst().resume()
    }
}

private let marmotRuntimeTestGate = AsyncTestGate(
    permits: max(1, ProcessInfo.processInfo.activeProcessorCount / 4)
)

struct MarmotRuntimeConcurrencyLimit: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let trace = GateTrace.shared
        let requested = Date()
        try await marmotRuntimeTestGate.withLock {
            let acquired = Date()
            defer { trace?.record(test: test, requested: requested, acquired: acquired, released: Date()) }
            try await function()
        }
    }
}

/// Opt-in JSONL trace of gate waits, for the audit's critical-path analysis
/// (`scripts/audit/gate-critical-path.py`). Enabled by `WN_TEST_GATE_TRACE=1`
/// in the host environment (pass `TEST_RUNNER_WN_TEST_GATE_TRACE=1` to
/// xcodebuild); appends to `gate-trace-<pid>.jsonl` in the host's temporary
/// directory, one file per host launch (Xcode launches the host for discovery
/// and again to run; a relaunch after a crash gets its own file instead of
/// truncating the earlier records).
final class GateTrace: Sendable {
    static let shared: GateTrace? = {
        guard ProcessInfo.processInfo.environment["WN_TEST_GATE_TRACE"] == "1" else { return nil }
        let name = "gate-trace-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        return GateTrace(handle: handle, path: url.path)
    }()

    let path: String
    private let handle: FileHandle
    private let lock = NSLock()

    private init(handle: FileHandle, path: String) {
        self.handle = handle
        self.path = path
    }

    func record(test: Test, requested: Date, acquired: Date, released: Date) {
        let record: [String: Any] = [
            "test": String(describing: test.id),
            "requested": requested.timeIntervalSince1970,
            "acquired": acquired.timeIntervalSince1970,
            "released": released.timeIntervalSince1970,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

extension Trait where Self == MarmotRuntimeConcurrencyLimit {
    static var marmotRuntimeConcurrencyLimit: Self { Self() }
}

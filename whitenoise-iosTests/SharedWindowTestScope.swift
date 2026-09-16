import Testing

#if compiler(>=6.3)
typealias WindowTestOperation = @concurrent @Sendable () async throws -> Void
#else
typealias WindowTestOperation = @Sendable () async throws -> Void
#endif

/// Window tests share one application scene, even across serialized suites.
struct SharedWindowTestScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Lock individual cases, never a suite or parameterized-test container.
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: WindowTestOperation
    ) async throws {
        try await Self.gate.run(function)
    }

    private static let gate = WindowTestGate()
}

actor WindowTestGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: WindowTestOperation) async throws {
        try Task.checkCancellation()
        if isOccupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isOccupied = true
        }
        defer { release() }
        // A cancelled waiter passes ownership on without touching the scene.
        try Task.checkCancellation()
        try await operation()
    }

    private func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

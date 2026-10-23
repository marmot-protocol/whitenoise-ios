import Foundation
import Synchronization
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

extension MarmotClient {
    static let unreachableTestRelays = ["wss://relay.invalid.test"]

    /// Builds a MarmotClient pointed at a unique temp directory so unit tests
    /// stay hermetic. The caller owns the runtime; prefer `withTestClient`,
    /// which closes it and removes the directory.
    static func testClient(relayUrls: [String] = unreachableTestRelays) throws -> MarmotClient {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            return try MarmotClient(rootPath: tmp.path, relayUrls: relayUrls)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

/// Runs `body` with a fresh `MarmotClient.testClient()`, then shuts the
/// runtime down whether `body` returns or throws. The temporary root is
/// removed only after a successful shutdown.
func withTestClient<T>(
    relayUrls: [String] = MarmotClient.unreachableTestRelays,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (MarmotClient) async throws -> T
) async throws -> T {
    let client = try MarmotClient.testClient(relayUrls: relayUrls)
    let result: T
    do {
        result = try await body(client)
    } catch {
        if (try? await client.marmot.shutdownAndClose()) != nil {
            try? FileManager.default.removeItem(atPath: client.rootPath)
        }
        throw error
    }
    try await client.marmot.shutdownAndClose()
    try? FileManager.default.removeItem(atPath: client.rootPath)
    return result
}

/// Runs `body`, then shuts `client` down whether `body` returns or throws. A
/// failed shutdown after a successful body is reported; after a failed body
/// the body's error wins. The root directory is kept, so a test may reopen it.
func closing<T>(
    _ client: MarmotClient,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    let result: T
    do {
        result = try await body()
    } catch {
        try? await client.marmot.shutdownAndClose()
        throw error
    }
    try await client.marmot.shutdownAndClose()
    return result
}

/// Stored-property shape for fixtures that keep a runtime across helper
/// calls. `close()` shuts the runtime down once and removes the root only
/// after that shutdown succeeds, so a runtime that may still be open never
/// loses its files.
final class OwnedTestClient: Sendable {
    let client: MarmotClient
    private let closed = Mutex(false)

    init(relayUrls: [String] = MarmotClient.unreachableTestRelays) throws {
        client = try MarmotClient.testClient(relayUrls: relayUrls)
    }

    func close() async throws {
        guard closed.withLock({ wasClosed in defer { wasClosed = true }; return !wasClosed }) else { return }
        try await client.marmot.shutdownAndClose()
        try? FileManager.default.removeItem(atPath: client.rootPath)
    }
}

/// Per-test owner for runtimes a suite cannot scope with `withTestClient`
/// because they are handed to an `AppState`, reopened on the same root, or
/// rebuilt by the app's own runtime factory. Apply `.closesTestRuntimes` to
/// the suite. After each test case, returned or thrown, every owned
/// `AppState` with a live runtime is suspended through the app's background
/// path, then every owned client and any client a state still holds is shut
/// down (`shutdownAndClose` is idempotent), and only then are owned roots
/// removed. A close failure fails a passing test; a test's own error wins.
final class TestRuntimeScope: Sendable {
    @TaskLocal static var current: TestRuntimeScope?

    struct MissingScope: Error, CustomStringConvertible {
        var description: String { "TestRuntimeScope.own needs a suite with .closesTestRuntimes" }
    }

    private struct Owned {
        var clients: [MarmotClient] = []
        var appStates: [AppState] = []
        var roots: Set<String> = []
    }

    private let owned = Mutex(Owned())

    private static func requireCurrent() throws -> TestRuntimeScope {
        guard let scope = current else {
            let error = MissingScope()
            Issue.record(error)
            throw error
        }
        return scope
    }

    /// Registers `client` with the running test's scope. `ownsRoot` removes
    /// its root directory once every runtime is closed.
    static func own(_ client: MarmotClient, ownsRoot: Bool = false) throws -> MarmotClient {
        let scope = try requireCurrent()
        scope.owned.withLock { owned in
            owned.clients.append(client)
            if ownsRoot { owned.roots.insert(client.rootPath) }
        }
        return client
    }

    /// Registers `appState` so its runtime, including one its lifecycle
    /// rebuilt, is suspended and closed too.
    @MainActor
    static func own(_ appState: AppState) throws -> AppState {
        let scope = try requireCurrent()
        scope.owned.withLock { $0.appStates.append(appState) }
        return appState
    }

    /// Returns the shutdown errors; the caller decides whether they fail the test.
    fileprivate func close() async -> [any Error] {
        let snapshot = owned.withLock { owned in
            defer { owned = Owned() }
            return owned
        }
        let live = await Self.suspend(snapshot.appStates)
        var errors: [any Error] = []
        for client in live + snapshot.clients {
            do {
                try await client.marmot.shutdownAndClose()
            } catch {
                errors.append(error)
            }
        }
        for root in snapshot.roots {
            try? FileManager.default.removeItem(atPath: root)
        }
        return errors
    }

    /// Suspends each live state so its lifecycle tasks drain before the
    /// snapshot, then returns any client a state still holds.
    @MainActor
    private static func suspend(_ states: [AppState]) async -> [MarmotClient] {
        for state in states {
            // A state still in `.bootstrapping` parks suspension until
            // bootstrap registers, so only suspend states past it.
            guard state.phase != .bootstrapping, state.client != nil,
                  !state.runtimeSuspendedForBackground else { continue }
            state.setAppSceneActive(false)
            await state.startRuntimeSuspension().value
        }
        return states.compactMap(\.client)
    }
}

struct ClosesTestRuntimes: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        let scope = TestRuntimeScope()
        try await TestRuntimeScope.$current.withValue(scope) {
            do {
                try await function()
            } catch {
                _ = await scope.close()
                throw error
            }
            for error in await scope.close() {
                Issue.record(error, "Closing a test runtime failed")
            }
        }
    }
}

extension Trait where Self == ClosesTestRuntimes {
    static var closesTestRuntimes: Self { Self() }
}

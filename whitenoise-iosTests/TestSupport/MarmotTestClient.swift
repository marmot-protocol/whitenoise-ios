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
        return try MarmotClient(rootPath: tmp.path, relayUrls: relayUrls)
    }
}

/// Runs `body` with a fresh `MarmotClient.testClient()`, then shuts the
/// runtime down and removes its temporary root, whether `body` returns or
/// throws.
func withTestClient<T>(
    relayUrls: [String] = MarmotClient.unreachableTestRelays,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (MarmotClient) async throws -> T
) async throws -> T {
    let client = try MarmotClient.testClient(relayUrls: relayUrls)
    defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
    return try await closing(client) { try await body(client) }
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
/// calls. `close()` shuts the runtime down once and then removes the root.
/// The root is never removed while the runtime may still be open.
final class OwnedTestClient: Sendable {
    let client: MarmotClient
    private let closed = Mutex(false)

    init(relayUrls: [String] = MarmotClient.unreachableTestRelays) throws {
        client = try MarmotClient.testClient(relayUrls: relayUrls)
    }

    func close() async throws {
        guard closed.withLock({ wasClosed in defer { wasClosed = true }; return !wasClosed }) else { return }
        defer { try? FileManager.default.removeItem(atPath: client.rootPath) }
        try await client.marmot.shutdownAndClose()
    }
}

/// Per-test owner for runtimes a suite cannot scope with `withTestClient`
/// because they are handed to an `AppState`, reopened on the same root, or
/// rebuilt by the app's own runtime factory. Apply `.closesTestRuntimes` to
/// the suite. After each test case, returned or thrown, every owned client
/// and the client each owned `AppState` then holds is shut down
/// (`shutdownAndClose` is idempotent), and only then are owned roots removed.
final class TestRuntimeScope: Sendable {
    @TaskLocal static var current: TestRuntimeScope?

    private struct Owned {
        var clients: [MarmotClient] = []
        var appStates: [AppState] = []
        var roots: Set<String> = []
    }

    private let owned = Mutex(Owned())

    /// Registers `client` with the running test's scope. `ownsRoot` removes
    /// its root directory once every runtime is closed.
    static func own(_ client: MarmotClient, ownsRoot: Bool = false) -> MarmotClient {
        guard let scope = current else {
            preconditionFailure("TestRuntimeScope.own needs a suite with .closesTestRuntimes")
        }
        scope.owned.withLock { owned in
            owned.clients.append(client)
            if ownsRoot { owned.roots.insert(client.rootPath) }
        }
        return client
    }

    /// Registers `appState` so the client it holds when the test ends,
    /// including one its lifecycle rebuilt, is closed too.
    @MainActor
    static func own(_ appState: AppState) -> AppState {
        guard let scope = current else {
            preconditionFailure("TestRuntimeScope.own needs a suite with .closesTestRuntimes")
        }
        scope.owned.withLock { $0.appStates.append(appState) }
        return appState
    }

    fileprivate func close() async {
        let snapshot = owned.withLock { owned in
            defer { owned = Owned() }
            return owned
        }
        let states = snapshot.appStates
        let live = await MainActor.run { states.compactMap(\.client) }
        for client in live + snapshot.clients {
            try? await client.marmot.shutdownAndClose()
        }
        for root in snapshot.roots {
            try? FileManager.default.removeItem(atPath: root)
        }
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
                await scope.close()
                throw error
            }
            await scope.close()
        }
    }
}

extension Trait where Self == ClosesTestRuntimes {
    static var closesTestRuntimes: Self { Self() }
}

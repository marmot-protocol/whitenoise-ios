import Foundation
import Synchronization
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

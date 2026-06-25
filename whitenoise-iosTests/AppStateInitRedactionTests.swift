import Testing
import Foundation
@testable import whitenoise_ios

/// #21 — the launch/rebuild fatalError messages must not interpolate the raw
/// error, whose description can leak internal Keychain/storage details into
/// crash logs. fatalError can't be exercised at runtime, so assert the source
/// keeps the redacted form.
struct AppStateInitRedactionTests {

    @Test func fatalErrorsDoNotInterpolateRawError() throws {
        let source = try String(contentsOf: appStateSourceURL, encoding: .utf8)

        // Leaky form: "...: \(error)"
        #expect(!source.contains("Marmot storage: \\(error)"))
        #expect(!source.contains("Marmot runtime: \\(error)"))

        // Redacted form: only the error type is surfaced.
        #expect(source.contains("Failed to initialize durable Marmot storage (\\(type(of: error)))"))
        #expect(source.contains("Failed to rebuild Keychain-backed Marmot runtime (\\(type(of: error)))"))
    }

    private var appStateSourceURL: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("whitenoise-ios/Core/AppState.swift")
    }
}

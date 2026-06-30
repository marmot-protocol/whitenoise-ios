import Foundation
import Testing
@testable import whitenoise_ios

/// #247 — chat-list and account relay-list storage reads must go through
/// MarmotClient async wrappers so generated synchronous FFI does not run on
/// MainActor-bound screens.
struct MarmotClientStorageReadOffloadTests {

    /// #318 — `AppState.relayLists(for:)` and the `relayPublishRelays` /
    /// `relayBootstrapRelays` accessors that funnel through it must be `async`
    /// and read account relay lists through the `MarmotClient.accountRelayLists`
    /// wrapper, so the generated synchronous FFI no longer runs on the MainActor
    /// profile-publish / profile-refresh paths.
    @Test func appStateRelayListAccessorsOffloadFfiAndAreAsync() throws {
        let appStateSource = try sourceString("whitenoise-ios/Core/AppState.swift")

        // The base accessor is async and reads through the MarmotClient wrapper,
        // not the synchronous `marmot.accountRelayLists` FFI.
        #expect(sourceContains(
            #"func relayLists\(for accountRef: String\) async -> AccountRelayListsFfi\?[\s\S]*currentMarmotClient\(\)\.accountRelayLists\("#,
            in: appStateSource
        ))
        #expect(
            !appStateSource.contains("marmot.accountRelayLists("),
            "AppState still calls the synchronous accountRelayLists FFI directly"
        )

        // The two callers that funnel through it are async too.
        #expect(sourceContains(
            #"func relayPublishRelays\(for accountRef: String\) async -> \[String\]"#,
            in: appStateSource
        ))
        #expect(sourceContains(
            #"func relayBootstrapRelays\(for accountRef: String\) async -> \[String\]"#,
            in: appStateSource
        ))

        // MainActor-bound callers must await the accessors rather than computing
        // from a synchronous read.
        let profileEditSource = try sourceString("whitenoise-ios/Settings/ProfileEditViewModel.swift")
        #expect(
            profileEditSource.contains("await appState.relayPublishRelays(for:"),
            "ProfileEditViewModel does not await relayPublishRelays"
        )
        #expect(
            profileEditSource.contains("await appState.relayBootstrapRelays(for:"),
            "ProfileEditViewModel does not await relayBootstrapRelays"
        )

        // refreshProfile moved to ProfileStore (Phase 2); it reaches the async
        // accessor through its AppState back-reference.
        let profileStoreSource = try sourceString("whitenoise-ios/Core/ProfileStore.swift")
        #expect(
            profileStoreSource.contains("await appState.relayBootstrapRelays(for:"),
            "refreshProfile does not await relayBootstrapRelays"
        )
        #expect(
            !profileStoreSource.contains("map(appState.relayBootstrapRelays(for:))"),
            "refreshProfile still uses the synchronous point-free relayBootstrapRelays accessor"
        )
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceContains(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }
}

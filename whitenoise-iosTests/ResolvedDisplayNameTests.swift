import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// #158 — SwiftUI rows read cached profile/display-name projections, while
/// preserving the established precedence: fetched kind:0 profile name →
/// runtime projected name → local account label.
@MainActor
struct ResolvedDisplayNameTests {
    private func profile(displayName: String? = nil, name: String? = nil) -> UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name, displayName: displayName, about: nil, picture: nil, nip05: nil, lud16: nil
        )
    }

    @Test func prefersProfileDisplayNameOverEverything() {
        #expect(AppState.resolvedKnownDisplayName(
            profile: profile(displayName: "Alice", name: "alice_ln"),
            projectedName: "Projected",
            localAccountLabel: "Label"
        ) == "Alice")
    }

    @Test func fallsBackToProfileNameThenProjectedThenLabel() {
        #expect(AppState.resolvedKnownDisplayName(
            profile: profile(displayName: nil, name: "alice_ln"), projectedName: nil, localAccountLabel: nil
        ) == "alice_ln")
        #expect(AppState.resolvedKnownDisplayName(
            profile: nil, projectedName: "Projected", localAccountLabel: "Label"
        ) == "Projected")
        #expect(AppState.resolvedKnownDisplayName(
            profile: nil, projectedName: nil, localAccountLabel: "My Account"
        ) == "My Account")
    }

    @Test func returnsNilWhenNothingKnown() {
        #expect(AppState.resolvedKnownDisplayName(profile: nil, projectedName: nil, localAccountLabel: nil) == nil)
        #expect(AppState.resolvedKnownDisplayName(profile: nil, projectedName: "", localAccountLabel: "") == nil)
    }

    @Test func ignoresWhitespaceOrControlOnlyLocalLabel() {
        // A blank/control-only label must not be returned (it would render empty
        // and suppress the npub fallback) — it's sanitized like any other name.
        #expect(AppState.resolvedKnownDisplayName(
            profile: nil, projectedName: nil, localAccountLabel: "   \n\t "
        ) == nil)
        #expect(AppState.resolvedKnownDisplayName(
            profile: nil, projectedName: nil, localAccountLabel: "\u{202E}\u{200B}"
        ) == nil)
    }

    @Test func stripsUnsafeCharactersFromResolvedName() {
        #expect(AppState.resolvedKnownDisplayName(
            profile: profile(displayName: "Ali\u{202E}ce"), projectedName: nil, localAccountLabel: nil
        ) == "Alice")
    }

    @Test func profileProjectionUsesResolvedNameAndAvatar() {
        let projection = ProfileDisplayProjection(
            profile: UserProfileMetadataFfi(
                name: nil,
                displayName: "Alice",
                about: nil,
                picture: "https://example.com/a.png",
                nip05: nil,
                lud16: nil
            ),
            projectedName: "Projected",
            localAccountLabel: "Label"
        )

        #expect(projection.knownDisplayName == "Alice")
        #expect(projection.avatarURL?.absoluteString == "https://example.com/a.png")
        #expect(projection.hasRemoteIdentity)
    }

    @Test func projectionMissDoesNotCountLocalLabelAsRemoteIdentity() {
        let projection = ProfileDisplayProjection(
            profile: nil,
            projectedName: nil,
            localAccountLabel: "Local"
        )

        #expect(projection.knownDisplayName == "Local")
        #expect(!projection.hasRemoteIdentity)
    }

    @Test func profileHelpersReadProjectionCacheInsteadOfMarmotOnMainActor() throws {
        let source = try sourceString("whitenoise-ios/Core/ProfileStore.swift")

        #expect(source.range(
            of: #"func profile\(forAccountIdHex id: String\) -> UserProfileMetadataFfi\? \{\s*cachedProfileProjection\(forAccountIdHex: id, refreshAfterLoad: true\)\?\.profile\s*\}"#,
            options: .regularExpression
        ) != nil)
        #expect(source.range(
            of: #"func knownDisplayName\(forAccountIdHex id: String\) -> String\? \{\s*cachedProfileProjection\(forAccountIdHex: id, refreshAfterLoad: true\)\?\.knownDisplayName\s*\}"#,
            options: .regularExpression
        ) != nil)
        #expect(source.range(
            of: #"func avatarURL\(forAccountIdHex id: String\) -> URL\? \{\s*cachedProfileProjection\(forAccountIdHex: id, refreshAfterLoad: true\)\?\.avatarURL\s*\}"#,
            options: .regularExpression
        ) != nil)
    }

    @Test func cacheMissHydrationIsDedupedBeforeRelayRefresh() throws {
        let source = try sourceString("whitenoise-ios/Core/ProfileStore.swift")

        #expect(source.contains("scheduledProfileProjectionLoadIDs.contains(id)"))
        #expect(source.contains("profileProjectionRefreshAfterLoadIDs.insert(id)"))
        #expect(source.contains("if shouldRefresh, projection?.hasRemoteIdentity != true"))
        #expect(source.contains("scheduleProfileRefresh(forAccountIdHex: id)"))
    }

    @Test func profilePublishRefreshesProjectionCache() throws {
        let source = try sourceString("whitenoise-ios/Settings/ProfileEditViewModel.swift")

        #expect(source.contains("await appState.reloadProfileProjection(forAccountIdHex: accountIdHex)"))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let testFile = URL(filePath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// #17 — with the iOS profile cache removed, display-name resolution is a pure
/// precedence function over the binding's values: fetched kind:0 profile name →
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

    @Test func stripsUnsafeCharactersFromResolvedName() {
        #expect(AppState.resolvedKnownDisplayName(
            profile: profile(displayName: "Ali\u{202E}ce"), projectedName: nil, localAccountLabel: nil
        ) == "Alice")
    }
}

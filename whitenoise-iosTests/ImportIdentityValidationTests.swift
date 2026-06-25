import Testing
@testable import whitenoise_ios

/// #40 — the Import button must only enable for a complete nsec, not any string
/// that merely starts with "nsec".
struct ImportIdentityValidationTests {

    @Test func rejectsIncompleteOrMalformedNsecInput() {
        #expect(!ImportIdentityView.isPlausibleNsec("nsec"))
        #expect(!ImportIdentityView.isPlausibleNsec("nsecfoo"))   // old hasPrefix("nsec") accepted this
        #expect(!ImportIdentityView.isPlausibleNsec("nsec1" + String(repeating: "a", count: 10)))
        #expect(!ImportIdentityView.isPlausibleNsec("npub1" + String(repeating: "a", count: 58)))
    }

    @Test func acceptsCanonicalLengthNsec() {
        let nsec = "nsec1" + String(repeating: "a", count: 58) // 63 chars total
        #expect(ImportIdentityView.isPlausibleNsec(nsec))
        #expect(ImportIdentityView.isPlausibleNsec("  \(nsec)\n"))
    }

    @Test func consumeIdentityForImportClearsVisibleSecretState() {
        let nsec = "nsec1" + String(repeating: "a", count: 58)
        var identity = "  \(nsec)\n"

        let consumed = ImportIdentityView.consumeIdentityForImport(&identity)

        #expect(consumed == nsec)
        #expect(identity.isEmpty)
    }
}

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

    /// #439 — a fast double-tap must not start two concurrent imports. The
    /// synchronous in-flight gate `runImport` takes before consuming the visible
    /// secret admits only the first caller; a re-entrant call is rejected without
    /// re-arming the flag or touching the field.
    @Test @MainActor func beginImportIfIdleRejectsReentrantImport() {
        let model = ImportIdentityViewModel()
        model.identity = "nsec1" + String(repeating: "a", count: 58)

        #expect(model.beginImportIfIdle())
        #expect(model.isImporting)

        // A second tap before the first import completes is rejected and leaves
        // the visible secret untouched for the still-running first import.
        #expect(!model.beginImportIfIdle())
        #expect(model.isImporting)
        #expect(!model.identity.isEmpty)
    }
}

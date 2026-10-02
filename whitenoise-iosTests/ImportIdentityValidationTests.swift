import Testing
import UIKit
import MarmotKit
@testable import whitenoise_ios

/// #40 — the Import button must only enable for a complete nsec, not any string
/// that merely starts with "nsec".
struct ImportIdentityValidationTests {
    private let validNsec = "nsec1j4c6269y9w0q2er2xjw8sv2ehyrtfxq3jwgdlxj6qfn8z4gjsq5qfvfk99"

    @Test func rejectsIncompleteOrMalformedNsecInput() {
        #expect(!ImportIdentityView.isPlausibleNsec("nsec"))
        #expect(!ImportIdentityView.isPlausibleNsec("nsecfoo"))   // old hasPrefix("nsec") accepted this
        #expect(!ImportIdentityView.isPlausibleNsec("nsec1" + String(repeating: "a", count: 10)))
        #expect(!ImportIdentityView.isPlausibleNsec("npub1" + String(repeating: "a", count: 58)))
        #expect(!ImportIdentityView.isPlausibleNsec("https://signer.example/connect"))
        #expect(!ImportIdentityView.isPlausibleNsec("bunker://remote-signer.example"))
        #expect(!ImportIdentityView.isPlausibleNsec("nsec1" + String(repeating: "a", count: 58)))
    }

    @Test func acceptsChecksumValidNsec() {
        #expect(ImportIdentityView.isPlausibleNsec(validNsec))
        #expect(ImportIdentityView.isPlausibleNsec("  \(validNsec)\n"))
        #expect(ImportIdentityView.isPlausibleNsec(validNsec.uppercased()))
    }

    @Test func consumeIdentityForImportClearsVisibleSecretState() {
        var identity = "  \(validNsec.uppercased())\n"

        let consumed = ImportIdentityView.consumeIdentityForImport(&identity)

        #expect(consumed == validNsec)
        #expect(identity.isEmpty)
    }

    /// #439 — a fast double-tap must not start two concurrent imports. The
    /// synchronous in-flight gate `runImport` takes before consuming the visible
    /// secret admits only the first caller; a re-entrant call is rejected without
    /// re-arming the flag or touching the field.
    @Test @MainActor func beginImportIfIdleRejectsReentrantImport() {
        let model = ImportIdentityViewModel()
        model.identity = validNsec

        #expect(model.beginImportIfIdle())
        #expect(model.isImporting)

        // A second tap before the first import completes is rejected and leaves
        // the visible secret untouched for the still-running first import.
        #expect(!model.beginImportIfIdle())
        #expect(model.isImporting)
        #expect(!model.identity.isEmpty)
    }

    @Test @MainActor func onlyAmbiguousPreJournalSetupRequestsExplicitRecovery() {
        #expect(ImportIdentityViewModel.requiresIncompleteSetupRecovery(
            MarmotKitError.AccountSetupRecoveryRequired
        ))
        #expect(!ImportIdentityViewModel.requiresIncompleteSetupRecovery(
            MarmotKitError.AccountSetupRetryRequired
        ))
        #expect(!ImportIdentityViewModel.requiresIncompleteSetupRecovery(
            MarmotKitError.AccountSetupKeyPackageRecoveryAvailable
        ))
    }

    @Test func redactedImportErrorStripsSecretShapedTokens() {
        // Login/parse errors can echo the rejected input; anything nsec- or
        // key-hex-shaped must not reach the persistent error label or toast.
        let nsec = "nsec1" + String(repeating: "q", count: 58)
        #expect(
            ImportIdentityView.redactedImportError("invalid secret key: \(nsec)")
                == "invalid secret key: nsec1…"
        )
        let hex = String(repeating: "ab", count: 32)
        #expect(
            ImportIdentityView.redactedImportError("bad key \(hex) rejected")
                == "bad key … rejected"
        )
        // Ordinary failure text passes through untouched.
        #expect(ImportIdentityView.redactedImportError("Relay unreachable") == "Relay unreachable")
    }

    @Test @MainActor func invalidRuntimeIdentityUsesTheInlineValidationCopy() {
        let message = ImportIdentityViewModel.importFallbackMessage(
            for: MarmotKitError.InvalidIdentity(details: "bad key")
        )

        #expect(message == "That private key isn't valid. Check it and try again.")
    }

    @Test @MainActor func keyPackagePublishFailureExplainsThatImportCanResume() {
        let message = ImportIdentityViewModel.importFallbackMessage(
            for: MarmotKitError.Publish(details: "publish timed out")
        )

        #expect(message == "Identity setup can be resumed. Try importing again.")
    }

    @Test @MainActor func dismissWithoutImportScrubsShadowCopyAndPasteboard() {
        let pasteboard = InMemorySensitivePasteboard()
        let model = ImportIdentityViewModel()
        let nsec = validNsec
        pasteboard.string = nsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        model.identity = nsec
        model.recordPastedClipboardToken(token, resultingIdentity: nsec)
        #expect(model.pastedClipboardToken != nil)
        #expect(model.clipboardTokenForImportedIdentity(nsec) != nil)

        // The sheet's onDisappear path: every exit clears the visible field,
        // the matching pasteboard generation, and the in-memory shadow copy.
        model.scrubDismissedImportState(pasteboard: pasteboard)

        #expect(model.identity.isEmpty)
        #expect(model.pastedClipboardToken == nil)
        #expect(model.clipboardTokenForImportedIdentity(nsec) == nil)
        #expect(!pasteboard.hasStrings)
    }

    @Test @MainActor func dismissScrubLeavesClipboardTheUserChangedAfterPasting() {
        let pasteboard = InMemorySensitivePasteboard()
        let model = ImportIdentityViewModel()
        let nsec = validNsec
        pasteboard.string = nsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        model.recordPastedClipboardToken(token, resultingIdentity: nsec)
        // The user copied something else after pasting; the stale token must
        // not clobber it.
        pasteboard.string = "unrelated"

        model.scrubDismissedImportState(pasteboard: pasteboard)

        #expect(model.pastedClipboardToken == nil)
        #expect(pasteboard.string == "unrelated")
    }
}

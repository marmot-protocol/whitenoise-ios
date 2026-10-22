import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct SensitiveClipboardTests {

    @Test func clearWipesPasteboardWhenUserHasNotChangedItSinceCapture() {
        let pasteboard = makeIsolatedPasteboard()
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret
        let token = SensitiveClipboard.capture(from: pasteboard)

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(pasteboard.string == nil || pasteboard.string?.isEmpty == true)
        #expect(!pasteboard.hasStrings)
    }

    @Test func clearLeavesPasteboardAloneWhenUserCopiedSomethingElseAfterCapture() {
        let pasteboard = makeIsolatedPasteboard()
        let secret = "nsec1examplesecretkeythatshouldnotleak"
        pasteboard.string = secret
        let token = SensitiveClipboard.capture(from: pasteboard)

        // User copies something new after the secret was captured — this bumps
        // the pasteboard's changeCount, so the clear must back off.
        let unrelated = "https://example.com/some-link"
        pasteboard.string = unrelated

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func clearIsNoOpWhenPasteboardHasNoStringEvenIfChangeCountMatches() {
        let pasteboard = makeIsolatedPasteboard()
        pasteboard.items = []
        let token = SensitiveClipboard.capture(from: pasteboard)

        SensitiveClipboard.clear(matching: token, from: pasteboard)

        #expect(!pasteboard.hasStrings)
    }

    @Test func copyStoresSensitiveTextWithExpirationOptions() throws {
        let pasteboard = makeIsolatedPasteboard()
        let expiry = Date().addingTimeInterval(120)

        SensitiveClipboard.copy("private message", to: pasteboard, expiresAt: expiry)

        #expect(pasteboard.string == "private message")
        #expect(pasteboard.lastOptions[.expirationDate] as? Date == expiry)
        #expect(pasteboard.lastOptions[.localOnly] as? Bool == true)
    }

    // Regression test for the #409 PR review BLOCKING finding: a nil token
    // (no genuine paste observed — the nsec was typed/autofilled, or the user
    // pasted then copied unrelated content so the token was never captured for
    // the live generation) must NEVER wipe the clipboard.
    @Test func shouldClearReturnsFalseWhenNoPasteWasObserved() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: nil,
            currentChangeCount: 7,
            hasStrings: true
        ) == false)
    }

    @Test func shouldClearReturnsTrueWhenGenerationUnchangedAndHasStrings() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 4,
            hasStrings: true
        ) == true)
    }

    // User copied something after the paste: the generation advanced, so we
    // must not clobber their newer content.
    @Test func shouldClearReturnsFalseWhenGenerationAdvancedAfterPaste() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 5,
            hasStrings: true
        ) == false)
    }

    @Test func shouldClearReturnsFalseWhenPasteboardHasNoStrings() {
        #expect(SensitiveClipboard.shouldClear(
            capturedChangeCount: 4,
            currentChangeCount: 4,
            hasStrings: false
        ) == false)
    }

    // A nil token routed through clear(matching:) must be a guaranteed no-op,
    // even when the pasteboard currently holds an unrelated string — this is
    // the typed/autofilled or paste-then-copy-unrelated case from the #409
    // blocking finding.
    @Test func clearIsNoOpWhenTokenIsNilEvenIfPasteboardHasStrings() {
        let pasteboard = makeIsolatedPasteboard()
        let unrelated = "https://example.com/unrelated"
        pasteboard.string = unrelated

        SensitiveClipboard.clear(matching: nil, from: pasteboard)

        #expect(pasteboard.string == unrelated)
    }

    @Test func importClearIgnoresNilTokenFromPartialPasteIntoExistingText() {
        let pasteboard = makeIsolatedPasteboard()
        let fragment = "nsec-fragment-from-clipboard"
        let resultingNsec = validNsec(filledWith: "d")
        pasteboard.string = fragment
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(nil, resultingIdentity: resultingNsec)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(resultingNsec),
            from: pasteboard
        )

        #expect(pasteboard.string == fragment)
    }

    @Test func importClearIgnoresTokenFromNonNsecPasteEditedIntoNsec() {
        let pasteboard = makeIsolatedPasteboard()
        let unrelated = "https://example.com/unrelated"
        pasteboard.string = unrelated
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: unrelated)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(validNsec(filledWith: "a")),
            from: pasteboard
        )

        #expect(pasteboard.string == unrelated)
    }

    @Test func importClearIgnoresTokenWhenPastedNsecWasEditedToDifferentNsec() {
        let pasteboard = makeIsolatedPasteboard()
        let pastedNsec = validNsec(filledWith: "a")
        let importedNsec = validNsec(filledWith: "b")
        pasteboard.string = pastedNsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: pastedNsec)
        SensitiveClipboard.clear(
            matching: model.clipboardTokenForImportedIdentity(importedNsec),
            from: pasteboard
        )

        #expect(pasteboard.string == pastedNsec)
    }

    @Test func importClearUsesTokenWhenImportedNsecStillMatchesPastedNsec() {
        let pasteboard = makeIsolatedPasteboard()
        let nsec = validNsec(filledWith: "c")
        pasteboard.string = nsec
        let token = SensitiveClipboard.capture(from: pasteboard)
        let model = ImportIdentityViewModel()

        model.recordPastedClipboardToken(token, resultingIdentity: " \n\(nsec)\n ")
        let clipboardToken = model.consumeClipboardTokenForImportedIdentity(nsec)
        SensitiveClipboard.clear(
            matching: clipboardToken,
            from: pasteboard
        )

        #expect(clipboardToken != nil)
        #expect(model.clipboardTokenForImportedIdentity(nsec) == nil)
        #expect(!pasteboard.hasStrings)
    }

    private func makeIsolatedPasteboard() -> InMemorySensitivePasteboard {
        InMemorySensitivePasteboard()
    }

    private func validNsec(filledWith character: Character) -> String {
        switch character {
        case "a":
            "nsec1afh3nysthqh47awpdewcw59wvvp499f8dvlyclmnv4gvpxdk56dsa6eqsn"
        case "b":
            "nsec12kcgs78l06p30jz7z7h3n2x2cy99nw2z6zspjdp7qc206887mwvs95lnkx"
        case "c":
            "nsec1c9wh8xy5eqdzln7n5t0ctgxjcrdug73gp5yj0x03gntn67h83twssdfhel"
        case "d":
            "nsec18t096ty4lzm8k3d86rn0yszmwrcrntmaylkavjgwwvh6w90a9wus2u8rgf"
        default:
            preconditionFailure("Missing valid nsec fixture")
        }
    }
}

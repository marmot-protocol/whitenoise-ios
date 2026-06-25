import UIKit

/// Removes a freshly consumed secret from `UIPasteboard` so it doesn't sit on
/// the shared system clipboard where any other app can read it.
///
/// Used after the user pastes an `nsec` into the import flow: once the
/// identity is imported, the bech32 secret has no business lingering on the
/// shared pasteboard, where any backgrounded app can read it via
/// `UIPasteboard.general.string`.
enum SensitiveClipboard {
    static let defaultExpirationInterval: TimeInterval = 120

    static func copy(
        _ text: String,
        to pasteboard: UIPasteboard = .general,
        expiresAt: Date = Date().addingTimeInterval(defaultExpirationInterval)
    ) {
        pasteboard.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: expiresAt]
        )
    }

    /// A token capturing the pasteboard's generation (its `changeCount`) at the
    /// moment a genuine user paste was observed, so a later `clear` can tell
    /// whether the user has since replaced the clipboard contents — without
    /// re-reading the secret.
    ///
    /// Capture this from a real paste event (`UITextView.paste(_:)`), BEFORE
    /// `super.paste(...)` runs — not at import-button tap. A paste event is the
    /// only signal that proves the clipboard's current generation is the secret
    /// the user pasted. Capturing at import tap is wrong: by then the user may
    /// have typed/autofilled the field or copied unrelated content, and the
    /// gate would clobber clipboard data the secret no longer owns (#409).
    struct Token {
        fileprivate let changeCount: Int
        fileprivate init(changeCount: Int) { self.changeCount = changeCount }
    }

    /// Snapshot the pasteboard's current change count from a paste event.
    ///
    /// Reads only `UIPasteboard.changeCount` (cheap metadata), so it does NOT
    /// raise the iOS 16+ "… pasted from …" disclosure banner the way reading
    /// `pasteboard.string` would. Call this from the paste interception
    /// (`onPaste`), not at import tap, so the captured generation provably
    /// belongs to the pasted secret.
    static func capture(from pasteboard: UIPasteboard = .general) -> Token {
        Token(changeCount: pasteboard.changeCount)
    }

    /// Pure decision for whether the pasteboard still provably holds the pasted
    /// secret and may therefore be wiped. Extracted so the gate can be unit
    /// tested without UIKit views.
    ///
    /// Returns true iff a paste was actually observed (`capturedChangeCount`
    /// is non-nil), the clipboard generation is unchanged since that paste, and
    /// the clipboard currently holds a string. A nil `capturedChangeCount`
    /// means no genuine paste was seen (typed/autofilled, or never pasted) and
    /// is a guaranteed no-op so unrelated clipboard contents are never wiped.
    static func shouldClear(
        capturedChangeCount: Int?,
        currentChangeCount: Int,
        hasStrings: Bool
    ) -> Bool {
        guard let capturedChangeCount else { return false }
        return capturedChangeCount == currentChangeCount && hasStrings
    }

    /// Wipe the pasteboard if it provably still holds the secret the user
    /// pasted since `token` was captured.
    ///
    /// We gate on `UIPasteboard.changeCount` rather than reading
    /// `pasteboard.string` and comparing it to the secret. Reading the string
    /// on iOS 16+ surfaces the system paste-disclosure banner and registers a
    /// programmatic clipboard access — an ironic privacy regression in a
    /// privacy helper, and the exact thing this helper exists to avoid (the
    /// pasted `nsec` typically originates in another app, e.g. a password
    /// manager). `changeCount` and `hasStrings` are both disclosure-free.
    ///
    /// `token` is optional: a nil token means no genuine paste was observed
    /// (the user typed/autofilled the field, or pasted then copied unrelated
    /// content), so the clear is a guaranteed no-op and we never blow away the
    /// user's newer/unrelated clipboard contents (#409). If the change count
    /// still matches the captured token, the clipboard holds the same item the
    /// user pasted, so we wipe it; if the user copied something else in the
    /// meantime the count has advanced and we leave their newer contents alone.
    ///
    /// Uses `setItems([], options: [.expirationDate: Date()])` so the cleared
    /// pasteboard isn't republished as an empty string that other apps would
    /// see as a fresh copy event.
    static func clear(matching token: Token?, from pasteboard: UIPasteboard = .general) {
        guard shouldClear(
            capturedChangeCount: token?.changeCount,
            currentChangeCount: pasteboard.changeCount,
            hasStrings: pasteboard.hasStrings
        ) else { return }
        pasteboard.setItems([], options: [.expirationDate: Date()])
    }
}

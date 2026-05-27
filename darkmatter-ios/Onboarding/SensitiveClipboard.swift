import UIKit

/// Removes a freshly consumed secret from `UIPasteboard` so it doesn't sit on
/// the shared system clipboard where any other app can read it.
///
/// Used after the user pastes an `nsec` into the import flow: once the
/// identity is imported, the bech32 secret has no business lingering on the
/// shared pasteboard, where any backgrounded app can read it via
/// `UIPasteboard.general.string`.
///
/// We only clear when the pasteboard's current string still equals the
/// secret — that way, if the user pasted, then copied something else, we
/// don't blow away their newer clipboard contents.
enum SensitiveClipboard {

    /// Wipe `secret` from `pasteboard` if (and only if) it currently holds it.
    ///
    /// Uses `setItems([], options: [.expirationDate: Date()])` so the cleared
    /// pasteboard isn't republished as an empty string that other apps would
    /// see as a fresh copy event.
    static func clear(_ secret: String, from pasteboard: UIPasteboard = .general) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard pasteboard.hasStrings, pasteboard.string == trimmed else { return }
        pasteboard.setItems([], options: [.expirationDate: Date()])
    }
}

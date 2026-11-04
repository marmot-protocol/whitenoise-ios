import Foundation
import SwiftUI

/// Transient presentation state for key access through the existing audited APIs.
@MainActor
@Observable
final class IdentityViewModel {
    // Avoid the isolated-deinit task-local crash on older Swift runtimes (including iOS 26.2).
    // https://github.com/swiftlang/swift/issues/88036
    nonisolated deinit {}

    enum RawKeyAction: Equatable {
        case reveal, copy, export

        var title: String {
            switch self {
            case .reveal: L10n.string("Show Key")
            case .copy: L10n.string("Copy Key")
            case .export: L10n.string("Export Key")
            }
        }

        var confirmationTitle: String {
            switch self {
            case .reveal: L10n.string("Show Private Key?")
            case .copy: L10n.string("Copy Private Key?")
            case .export: L10n.string("Export Without a Password?")
            }
        }

        var confirmationMessage: String {
            switch self {
            case .reveal, .copy:
                L10n.string("Keep this key safe and don’t share it with anyone. Anyone with it can use your profile.")
            case .export:
                L10n.string("We recommend exporting with a password to protect your private key. Without one, anyone with the exported key can use your profile. Keep it safe and don’t share it.")
            }
        }
    }

    struct RawKeyRequest {
        let action: RawKeyAction
        let accountRef: String
        let presentationID: UUID
    }

    var rawKeyRequest: RawKeyRequest?
    var showEncryptedExportSheet = false {
        didSet {
            // Cancel and swipe dismissal must clear the sheet's error before
            // the underlying form becomes visible during the animation.
            if !showEncryptedExportSheet { exportError = nil }
        }
    }
    var exportShareText: String?
    private var pendingEncryptedShareText: String?
    private(set) var revealedNsec: String?
    var exportInFlight = false
    private(set) var rawActionInFlight: RawKeyAction?
    private(set) var copyFeedbackID: UUID?
    var privateKeyCopied = false
    var exportError: String?
    private var presentationID = UUID()

    /// Captures the account and presentation for consent without accessing its secret.
    func requestRawKey(_ action: RawKeyAction, using appState: AppState) {
        guard !exportInFlight, let accountRef = appState.activeAccountRef else { return }
        exportError = nil
        rawKeyRequest = RawKeyRequest(action: action, accountRef: accountRef, presentationID: presentationID)
    }

    /// Runs a confirmed action and discards results if its account or screen changed.
    func performRawKeyRequest(_ request: RawKeyRequest, using appState: AppState) async {
        guard !exportInFlight, appState.activeAccountRef == request.accountRef,
              presentationID == request.presentationID else { return }
        let requestID = presentationID
        exportInFlight = true
        rawActionInFlight = request.action
        exportError = nil
        defer {
            if presentationID == requestID {
                exportInFlight = false
                rawActionInFlight = nil
            }
        }

        do {
            let nsec = try await appState.revealNsec(accountRef: request.accountRef)
            guard presentationID == requestID,
                  appState.activeAccountRef == request.accountRef else { return }
            switch request.action {
            case .reveal:
                revealedNsec = nsec
            case .copy:
                SensitiveClipboard.copy(nsec)
                privateKeyCopied = true
                copyFeedbackID = UUID()
                AccessibilityNotification.Announcement(L10n.string("Copied")).post()
            case .export:
                exportShareText = nsec
            }
            Haptics.success()
        } catch {
            guard presentationID == requestID,
                  appState.activeAccountRef == request.accountRef else { return }
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
        }
    }

    func hidePrivateKey() {
        revealedNsec = nil
    }

    /// Prepares an encrypted backup, retaining failures in the sheet and staging
    /// successful sharing until the password sheet finishes dismissing.
    func exportEncryptedNsec(passphrase: String, using appState: AppState) async {
        guard !exportInFlight, let accountRef = appState.activeAccountRef else { return }
        let requestID = presentationID
        exportInFlight = true
        exportError = nil
        defer {
            if presentationID == requestID { exportInFlight = false }
        }

        do {
            let ncryptsec = try await appState.exportEncryptedSecretKey(
                accountRef: accountRef,
                passphrase: passphrase
            )
            guard presentationID == requestID,
                  appState.activeAccountRef == accountRef else { return }
            pendingEncryptedShareText = ncryptsec
            showEncryptedExportSheet = false
            Haptics.success()
        } catch {
            guard presentationID == requestID,
                  appState.activeAccountRef == accountRef else { return }
            Haptics.error()
            exportError = IdentityKeyExportPresentation.errorMessage(for: error)
        }
    }

    // Wait for the password sheet to finish dismissing before presenting sharing.
    func encryptedSheetDismissed() {
        exportShareText = pendingEncryptedShareText
        pendingEncryptedShareText = nil
    }

    func clearPresentation() {
        presentationID = UUID()
        revealedNsec = nil
        rawKeyRequest = nil
        showEncryptedExportSheet = false
        pendingEncryptedShareText = nil
        exportShareText = nil
        exportError = nil
        exportInFlight = false
        rawActionInFlight = nil
        privateKeyCopied = false
        copyFeedbackID = nil
    }
}

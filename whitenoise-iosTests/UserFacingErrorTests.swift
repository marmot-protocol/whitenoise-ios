import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct UserFacingErrorTests {
    private struct RuntimeError: LocalizedError {
        let errorDescription: String?
    }

    @Test func mediaFailuresUseTypedCopyInsteadOfRemoteDetails() {
        let detail = "Peer supplied diagnostic location"
        let cases: [(MarmotKitError, String)] = [
            (.MediaAttachmentRejected(kind: .unsupportedFormat, details: detail), "Unsupported attachment"),
            (.MediaUnfetchable(details: detail), "No safe download location is available for this attachment."),
            (.MediaDownloadFailed(details: detail), "Attachment download failed. Please try again."),
        ]
        for (error, expected) in cases {
            #expect(UserFacingError.message(for: error) == expected)
            #expect(UserFacingError.sanitizedDiagnostic(for: error) == detail)
        }
    }

    @Test func typedDuplicateIdentityUsesActionableCopy() {
        let error = MarmotKitError.DuplicateIdentity(account: "existing-account")

        let presentation = UserFacingError.present(title: "Import failed", error: error)

        #expect(presentation.title == "Import failed")
        #expect(presentation.message == "Identity already signed in on this device")
        #expect(!presentation.message.contains("MarmotKit"))
    }

    @Test func legacyDuplicateIdentityDiagnosticUsesActionableCopy() {
        let error = RuntimeError(errorDescription: "MarmotKit.MarmotKitError.Runtime(details: \"account id is already in use: abc\")")

        let presentation = UserFacingError.present(title: "Import failed", error: error)

        #expect(presentation.message == "Identity already signed in on this device")
        #expect(presentation.diagnostic.contains("account id is already in use"))
    }

    @Test func diagnosticsRedactSecretShapedInput() {
        let secret = "nsec1" + String(repeating: "q", count: 58)
        let error = RuntimeError(errorDescription: "runtime rejected \(secret)")

        let diagnostic = UserFacingError.sanitizedDiagnostic(for: error)

        #expect(diagnostic == "Runtime rejected nsec1…")
    }

    @Test func accountSetupErrorsUseActionableCopy() {
        let recovery = UserFacingError.present(
            title: "Import failed",
            error: MarmotKitError.AccountSetupRecoveryRequired
        )
        let retry = UserFacingError.present(
            title: "Import failed",
            error: MarmotKitError.AccountSetupRetryRequired
        )

        #expect(recovery.message == "Incomplete identity setup needs approval to recover.")
        #expect(retry.message == "Identity setup can be resumed. Try importing again.")
    }

    @Test(arguments: [
        ("network timed out", "Network timed out"),
        ("  recipient KeyPackage incompatible", "Recipient KeyPackage incompatible"),
        ("“relay” returned HTTP 503", "“Relay” returned HTTP 503"),
        ("échec du relais", "Échec du relais"),
        ("HTTP 503", "HTTP 503"),
        ("503", "503")
    ])
    func ordinaryFailuresKeepTheOperationTitleAndReadableMessage(_ input: String, _ expected: String) {
        let error = RuntimeError(errorDescription: input)

        let toast = UserFacingError.toast(title: "send failed", error: error)

        #expect(toast.title == "Send failed")
        #expect(toast.message == expected)
        #expect(toast.diagnostic == nil)
    }

    @Test(arguments: [
        MarmotKitError.Runtime(details: "Recipient needs to regenerate their KeyPackage."),
        .Publish(details: "Recipient needs to regenerate their KeyPackage."),
        .AccountCatchUp(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidChatPin(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidMessageDraft(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidMediaReference(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidHex(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidIdentity(details: "Recipient needs to regenerate their KeyPackage."),
        .InvalidKeyPackageEvent(details: "Recipient needs to regenerate their KeyPackage."),
        .StorageBusy(details: "Recipient needs to regenerate their KeyPackage."),
        .StorageClosed(details: "Recipient needs to regenerate their KeyPackage."),
        .SecretNotFound(details: "Recipient needs to regenerate their KeyPackage."),
        .KeystoreUnavailable(details: "Recipient needs to regenerate their KeyPackage."),
        .EncryptionFailed(details: "Recipient needs to regenerate their KeyPackage."),
        .Io(details: "Recipient needs to regenerate their KeyPackage.")
    ])
    func marmotDetailsAreDisplayedWithoutTheGeneratedWrapper(_ error: MarmotKitError) {
        let expected = "Recipient needs to regenerate their KeyPackage."
        let toast = UserFacingError.toast(title: "Couldn't create chat", error: error)
        #expect(toast.title == "Couldn't create chat")
        #expect(toast.message == expected)
        #expect(toast.diagnostic == nil)
        #expect(UserFacingError.message(for: error) == expected)
        #expect(UserFacingError.sanitizedDiagnostic(for: error) == expected)
    }

    @Test func detailsPreserveQuotesAndNewlinesAndRedactSecrets() {
        let secret = "nsec1" + String(repeating: "q", count: 58)
        let hex = String(repeating: "a", count: 64)
        let error = MarmotKitError.Runtime(details: "Could not use \"key\".\nRejected \(secret) and \(hex)")
        let expected = "Could not use \"key\".\nRejected nsec1… and …"
        #expect(UserFacingError.message(for: error) == expected)
        #expect(UserFacingError.sanitizedDiagnostic(for: error) == expected)
        #expect(UserFacingError.message(for: MarmotKitError.Runtime(details: String(repeating: "x", count: 5_000))).count == 4_000)
    }

    @Test func emptyAndUnmappedErrorsHaveReadableFallbacks() {
        for error in [MarmotKitError.Runtime(details: " \n"), .UnknownGroup(groupIdHex: "private-id")] {
            #expect(UserFacingError.message(for: error) == "Please try again.")
            #expect(!UserFacingError.sanitizedDiagnostic(for: error).contains("MarmotKit"))
            #expect(UserFacingError.toast(title: "Operation failed", error: error).diagnostic == nil)
        }
    }

    @Test func contextualFallbackAndRelayWrappedErrorsUseSharedFormatting() {
        let error = MarmotKitError.Runtime(details: "Relay unavailable")
        let wrapped = RelaySettingsSaveFailure(underlyingError: error, reloadedLists: nil)
        #expect(UserFacingError.message(for: wrapped) == "Relay unavailable")
        #expect(UserFacingError.sanitizedDiagnostic(for: wrapped) == "Relay unavailable")
        let toast = UserFacingError.toast(title: "Import failed", error: error, fallbackMessage: "Try importing again.")
        #expect(toast.message == "Try importing again.")
        #expect(toast.diagnostic == "Relay unavailable")
    }

    @Test func fullGroupSendQueueExplainsWhenToResend() {
        let presentation = UserFacingError.present(
            title: "Send failed",
            error: MarmotKitError.GroupSendQueueFull(groupIdHex: "group-id")
        )

        #expect(presentation.message == "This chat is still catching up. Wait for it to finish, then resend your message.")
        #expect(!presentation.message.contains("group-id"))
    }

    @Test func unrecoverableGroupExplainsThatRetryCannotRepairIt() {
        let presentation = UserFacingError.present(
            title: "Send failed",
            error: MarmotKitError.GroupUnrecoverableRepairRequired(groupIdHex: "group-id")
        )

        #expect(presentation.message == "This conversation needs to be rejoined before you can send messages.")
        #expect(!presentation.message.contains("group-id"))
    }

    @Test func accountWorkerErrorsDistinguishSafeRetryFromUnknownCompletion() {
        let busy = UserFacingError.present(
            title: "Operation failed",
            error: MarmotKitError.AccountWorkerBusy
        )
        let timedOut = UserFacingError.present(
            title: "Operation failed",
            error: MarmotKitError.AccountWorkerResponseTimedOut
        )

        #expect(busy.message == "This account is still catching up. Try again in a moment.")
        #expect(timedOut.message.contains("may have completed"))
        #expect(timedOut.message.contains("before retrying"))
    }
}

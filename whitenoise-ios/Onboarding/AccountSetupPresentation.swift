import Foundation
import MarmotKit

nonisolated enum AccountSetupPresentation {
    static func title(_ step: OnboardingStepFfi) -> String {
        switch step {
        case .profile: L10n.string("Your profile")
        case .follows: L10n.string("People you follow")
        case .relays: L10n.string("Your relays")
        case .inboxRelays: L10n.string("Message inbox")
        case .singleDevice: L10n.string("Using one device")
        case .keyPackage: L10n.string("Secure messaging")
        }
    }

    static func status(_ status: OnboardingStatusFfi) -> String {
        switch status {
        case .pending: L10n.string("Waiting")
        case .checking: L10n.string("Checking…")
        case .passed: L10n.string("Done")
        case .needsInput: L10n.string("Needs your attention")
        case .retryableFailure: L10n.string("Couldn’t finish this check")
        case .waitingForSigner: L10n.string("Couldn’t access your private key")
        case .skipped: L10n.string("Skipped")
        }
    }

    static func symbol(_ status: OnboardingStatusFfi) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .needsInput, .retryableFailure: "exclamationmark.circle"
        case .waitingForSigner: "key"
        case .checking, .pending: "circle"
        }
    }

    static func deviceAction(_ discovery: OnboardingDeviceDiscoveryFfi?) -> String {
        discovery == .noneFound ? L10n.string("Continue") : L10n.string("Continue anyway")
    }

    static func deviceNotice(_ discovery: OnboardingDeviceDiscoveryFfi) -> String {
        switch discovery {
        case .otherInstallationPossible:
            L10n.string("We found signs of another installation. This can also happen after reinstalling. Invitations may reach only one installation, and chats will not appear on both.")
        case .noneFound:
            L10n.string("No other installation was found on the sources we checked. This does not guarantee that the profile is unused elsewhere.")
        case .unknown:
            L10n.string("We couldn’t determine whether another installation exists. Invitations may reach only one installation, and chats will not appear on both.")
        }
    }

    static func issue(_ issue: OnboardingIssueFfi) -> String {
        switch issue {
        case .missing: L10n.string("No published settings were found.")
        case .malformed: L10n.string("The published settings could not be read.")
        case .futureDated: L10n.string("The published settings have a future date. Check your device clock and retry.")
        case .invalidRelay: L10n.string("A relay address is invalid.")
        case .retiredRelay: L10n.string("A relay is no longer supported.")
        case .unsafeRelay: L10n.string("A relay address is not safe to connect to.")
        case .unreachable: L10n.string("A relay could not be reached.")
        case .timedOut: L10n.string("A relay did not respond in time. Your existing settings have not been replaced.")
        case .authenticationRequired: L10n.string("A relay requires authentication.")
        case .paymentRequired: L10n.string("A relay requires payment.")
        case .accessRestricted: L10n.string("A relay restricted access.")
        case .noUsableRoute: L10n.string("No usable relay route was found.")
        case .publicationFailed: L10n.string("Publishing did not finish. Retry to continue from the saved progress.")
        case .signerUnavailable: L10n.string("Your signer is unavailable.")
        case .signerRejected: L10n.string("Your signer declined the request.")
        case .recordChanged: L10n.string("The published settings changed. Check again before approving a repair.")
        case .interrupted: L10n.string("This check was interrupted. Your progress is saved.")
        case .tooManyRelays: L10n.string("The relay list is too large.")
        case .multiDeviceUnsupported: L10n.string("Conversations do not sync across devices yet.")
        case .otherInstallationPossible: L10n.string("Another installation may exist.")
        case .discoveryIncomplete: L10n.string("Some discovery sources could not be checked.")
        }
    }
}

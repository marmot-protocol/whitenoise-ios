import Foundation
import MarmotKit

nonisolated enum AccountSetupPresentation {
    static func findingMessages(_ findings: [OnboardingFindingFfi]) -> [String] {
        var seen: Set<String> = []
        return findings.compactMap { finding in
            var message = issue(finding.issue)
            if let endpoint = finding.endpoint {
                let scalars = endpoint.unicodeScalars.prefix(200).filter {
                    $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
                }
                let address = String(String.UnicodeScalarView(scalars))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !address.isEmpty { message += "\n" + address + (endpoint.unicodeScalars.count > 200 ? "…" : "") }
            }
            return seen.insert(message).inserted ? message : nil
        }
    }

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

    enum CheckState: Equatable {
        case pending, checking, passed, skipped
        case optionalProfile, optionalIssue, requiredFix, acknowledgment

        var subtitle: String {
            switch self {
            case .pending: L10n.string("Waiting")
            case .checking: L10n.string("Checking…")
            case .passed: L10n.string("Done")
            case .skipped: L10n.string("Skipped")
            case .optionalProfile, .optionalIssue: L10n.string("Review or skip")
            case .requiredFix: L10n.string("Fix to continue")
            case .acknowledgment: L10n.string("Review to continue")
            }
        }

        var symbol: String {
            switch self {
            case .pending, .checking: "circle"
            case .passed: "checkmark.circle.fill"
            case .skipped: "minus.circle"
            case .optionalProfile, .optionalIssue, .acknowledgment: "exclamationmark.triangle.fill"
            case .requiredFix: "xmark.circle.fill"
            }
        }

        var needsAttention: Bool {
            switch self {
            case .optionalProfile, .optionalIssue, .requiredFix, .acknowledgment: true
            case .pending, .checking, .passed, .skipped: false
            }
        }
    }

    static func checkState(_ step: OnboardingStepStateFfi) -> CheckState {
        switch step.status {
        case .pending: return .pending
        case .checking: return .checking
        case .passed: return .passed
        case .skipped: return .skipped
        case .needsInput, .retryableFailure, .waitingForSigner:
            if step.step == .singleDevice, step.actions.contains(.continueAnyway) {
                return .acknowledgment
            }
            // Only describe skipping when the current snapshot offers an action the UI supports.
            if (step.step == .profile || step.step == .follows), step.actions.contains(.continueWithout) {
                let isInvitation = step.status == .needsInput && step.findings.allSatisfy { $0.issue == .missing }
                return isInvitation ? .optionalProfile : .optionalIssue
            }
            return .requiredFix
        }
    }

    static func stepToReview(_ snapshot: OnboardingSnapshotFfi, isBusy: Bool) -> OnboardingStepFfi? {
        guard !isBusy, !snapshot.ready, !snapshot.cancellationPending,
              let step = snapshot.steps.first(where: { $0.status != .passed && $0.status != .skipped }),
              checkState(step).needsAttention else { return nil }
        return step.step
    }

    static func heading(_ snapshot: OnboardingSnapshotFfi, isBusy: Bool, hasError: Bool) -> String {
        if hasError { return L10n.string("Couldn’t continue signing in") }
        if snapshot.ready && !snapshot.cancellationPending { return L10n.string("You’re ready to chat") }
        if !isBusy, snapshot.steps.contains(where: { checkState($0).needsAttention }) {
            return L10n.string("A little more to do")
        }
        return L10n.string("Getting ready to chat")
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

import Foundation
import MarmotKit

/// Plain-language lines for a relay or inbox step's findings: what is wrong with
/// the list, each affected relay by host, then what the person can do next.
nonisolated enum AccountSetupRelayFindingPresentation {
    static func messages(
        step: OnboardingStepFfi, findings: [OnboardingFindingFfi], actions: [OnboardingActionFfi]
    ) -> [String] {
        let inbox = step == .inboxRelays
        // A relay that answered is not a problem, and MDK warns it doesn't prove write support.
        let problems = findings.filter { $0.issue != .inspectionCompleted && $0.outcome != .success }
        // Relays searched for the record are not necessarily in the person's list.
        let isLookup: (OnboardingFindingFfi) -> Bool = { $0.context == .recordDiscovery || $0.context == .repairApproval }
        let listProblems = problems.filter { !isLookup($0) }
        let lookupProblems = problems.filter(isLookup)
        let render: ([OnboardingFindingFfi]) -> [String] = { group in
            group.filter { $0.endpoint == nil }.map { listMessage($0, inbox: inbox) }
                + group.filter { $0.endpoint != nil }.map(relayMessage)
        }

        var lines = render(listProblems)
        let routeFailed = listProblems.contains {
            $0.issue == .noUsableRoute || ($0.context == .declaredRoute && $0.endpoint != nil)
        }
        if routeFailed { lines.append(routeAdvice(inbox: inbox, actions: actions)) }
        // Introduce the searched relays even when MDK reports only their individual failures.
        if lookupProblems.contains(where: { $0.endpoint != nil }) {
            lines.append(inbox ? L10n.string("Some relays couldn’t be searched for your message inbox.")
                : L10n.string("Some relays couldn’t be searched for your relay list."))
        }
        lines += render(lookupProblems)

        var seen: Set<String> = []
        return lines.filter { seen.insert($0).inserted }
    }

    /// The relay's host as bounded, untrusted display text.
    static func host(_ endpoint: String) -> String? {
        let bounded = String(String.UnicodeScalarView(endpoint.unicodeScalars.prefix(512)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URLComponents(string: bounded)?.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return ContentSanitizer.relayDisplayLine(host ?? bounded, maxLength: 120)
    }

    private static func listMessage(_ finding: OnboardingFindingFfi, inbox: Bool) -> String {
        switch finding.issue {
        case .noUsableRoute where finding.context == .declaredRoute:
            inbox ? L10n.string("None of the relays in your message inbox answered.")
                : L10n.string("None of the relays in your relay list answered.")
        case .noUsableRoute:
            inbox ? L10n.string("Your message inbox has no relay White Noise can use.")
                : L10n.string("Your relay list has no relay White Noise can use.")
        case .missing:
            inbox ? L10n.string("White Noise couldn’t find your message inbox.")
                : L10n.string("White Noise couldn’t find your relay list.")
        case .malformed:
            inbox ? L10n.string("Your message inbox couldn’t be read.")
                : L10n.string("Your relay list couldn’t be read.")
        case .tooManyRelays:
            inbox ? L10n.string("Your message inbox lists too many relays.")
                : L10n.string("Your relay list has too many relays.")
        case .discoveryIncomplete:
            inbox ? L10n.string("Some relays couldn’t be searched for your message inbox.")
                : L10n.string("Some relays couldn’t be searched for your relay list.")
        case .unreachable, .timedOut:
            inbox ? L10n.string("White Noise couldn’t reach a relay to look up your message inbox.")
                : L10n.string("White Noise couldn’t reach a relay to look up your relay list.")
        case .recordChanged:
            inbox ? L10n.string("Your message inbox changed during sign-in. Check it again before saving a fix.")
                : L10n.string("Your relay list changed during sign-in. Check it again before saving a fix.")
        case .publicationFailed:
            inbox ? L10n.string("Your updated message inbox wasn’t published.")
                : L10n.string("Your updated relay list wasn’t published.")
        default:
            AccountSetupPresentation.issue(finding.issue)
        }
    }

    private static func relayMessage(_ finding: OnboardingFindingFfi) -> String {
        guard let host = finding.endpoint.flatMap(host) else { return AccountSetupPresentation.issue(finding.issue) }
        switch finding.issue {
        case .unreachable: return L10n.formatted("%@ couldn’t be reached.", host)
        case .timedOut: return L10n.formatted("%@ didn’t answer in time.", host)
        case .authenticationRequired: return L10n.formatted("%@ requires sign-in that White Noise couldn’t complete.", host)
        case .paymentRequired: return L10n.formatted("%@ requires payment.", host)
        case .accessRestricted: return L10n.formatted("%@ restricts who can use it.", host)
        // Policy rejects an address in the published list; a query failure is the relay refusing the request.
        case .invalidRelay where finding.context == .publishedDeclaration:
            return L10n.formatted("%@ isn’t a valid relay address.", host)
        case .invalidRelay: return L10n.formatted("%@ refused White Noise’s request.", host)
        case .retiredRelay: return L10n.formatted("%@ is no longer supported.", host)
        case .unsafeRelay: return L10n.formatted("%@ isn’t safe to connect to.", host)
        default: return AccountSetupPresentation.issue(finding.issue) + "\n" + host
        }
    }

    /// Only suggest changes the current step offers; otherwise the list can only be fixed elsewhere.
    private static func routeAdvice(inbox: Bool, actions: [OnboardingActionFfi]) -> String {
        if actions.contains(.useRecommendedRelays) {
            return inbox ? L10n.string("Add White Noise’s default relays to your message inbox to continue.")
                : L10n.string("Add White Noise’s default relays to your relay list to continue.")
        }
        if actions.contains(.editRelays) {
            return inbox ? L10n.string("Add a relay that works to your message inbox to continue.")
                : L10n.string("Add a relay that works to your relay list to continue.")
        }
        return inbox
            ? L10n.string("If this keeps happening, add a relay that works to your message inbox in another Nostr app, then sign in again.")
            : L10n.string("If this keeps happening, add a relay that works to your relay list in another Nostr app, then sign in again.")
    }
}

import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct AccountSetupRelayFindingPresentationTests {
    private typealias Presentation = AccountSetupRelayFindingPresentation

    @Test func inboxFailureNamesTheListAndEachRelayByHost() {
        let findings = [
            relayFinding(.authenticationRequired, "wss://auth.example/"),
            relayFinding(.unreachable, "wss://dead.example"),
            relayFinding(.paymentRequired, "wss://paid.example:443/inbox"),
            relayFinding(.noUsableRoute, nil),
            relayFinding(.inspectionCompleted, "wss://ok.example", outcome: .success),
        ]
        let messages = Presentation.messages(step: .inboxRelays, findings: findings,
                                             actions: [.retry, .editDiscoveryRelays, .cancelOnboarding])
        #expect(messages == [
            L10n.string("None of the relays in your message inbox answered."),
            L10n.formatted("%@ requires sign-in that White Noise couldn’t complete.", "auth.example"),
            L10n.formatted("%@ couldn’t be reached.", "dead.example"),
            L10n.formatted("%@ requires payment.", "paid.example"),
            L10n.string("If this keeps happening, add a relay that works to your message inbox in another Nostr app, then sign in again."),
        ])
        let relayList = Presentation.messages(step: .relays, findings: findings, actions: [.retry])
        #expect(relayList.first == L10n.string("None of the relays in your relay list answered."))
        #expect(Set(relayList).isDisjoint(with: [messages[0], messages[4]]))
    }

    @Test(arguments: [OnboardingStepFfi.relays, .inboxRelays])
    func adviceSuggestsOnlyAChangeTheStepOffers(_ step: OnboardingStepFfi) {
        let findings = [relayFinding(.noUsableRoute, nil, context: .publishedDeclaration)]
        let advice = [
            [OnboardingActionFfi.useRecommendedRelays, .editRelays], [.editRelays], [.retry], [],
        ].map { Presentation.messages(step: step, findings: findings, actions: $0).last }
        #expect(Set(advice).count == 3)
        #expect(advice[2] == advice[3])
        let inbox = step == .inboxRelays
        #expect(advice[0] == (inbox
            ? L10n.string("Add White Noise’s default relays to your message inbox to continue.")
            : L10n.string("Add White Noise’s default relays to your relay list to continue.")))
    }

    @Test func searchedRelaysAreIntroducedSeparatelyFromTheList() {
        let slow = relayFinding(.timedOut, "wss://slow.example", context: .recordDiscovery)
        let summary = L10n.string("Some relays couldn’t be searched for your relay list.")
        let expected = [summary, L10n.formatted("%@ didn’t answer in time.", "slow.example")]
        #expect(Presentation.messages(step: .relays, findings: [slow], actions: [.retry]) == expected)
        // MDK's own incomplete-search notice is not repeated, and search failures never suggest list changes.
        let reported = relayFinding(.discoveryIncomplete, nil, context: .recordDiscovery)
        #expect(Presentation.messages(step: .relays, findings: [reported, slow], actions: [.editRelays]) == expected)
    }

    @Test func addressRejectionsDifferFromRelayRefusals() {
        let declared = relayFinding(.invalidRelay, "wss://bad.example", context: .publishedDeclaration)
        let queried = relayFinding(.invalidRelay, "wss://bad.example")
        let lines = Presentation.messages(step: .relays, findings: [declared, queried], actions: [])
        #expect(lines.prefix(2) == [
            L10n.formatted("%@ isn’t a valid relay address.", "bad.example"),
            L10n.formatted("%@ refused White Noise’s request.", "bad.example"),
        ])
    }

    @Test func relayHostsAreBoundedUntrustedText() {
        #expect(Presentation.host("wss://Relay.Example:4848/path?q=1") == "relay.example")
        let hostile = Presentation.host("\u{202e}wss://spoof.example\n" + String(repeating: "a", count: 2_000))
        #expect(hostile?.contains("\u{202e}") == false)
        #expect(hostile?.contains("\n") == false)
        #expect((hostile?.count ?? .max) <= 120)
        #expect(Presentation.host("\u{200b}") == nil)
        let unreadable = relayFinding(.unreachable, "\u{200b}")
        #expect(Presentation.messages(step: .relays, findings: [unreadable], actions: [])
            .contains(AccountSetupPresentation.issue(.unreachable)))
    }

    private func relayFinding(
        _ issue: OnboardingIssueFfi, _ endpoint: String?, context: OnboardingFindingContextFfi = .declaredRoute,
        outcome: OnboardingCheckOutcomeFfi = .failure
    ) -> OnboardingFindingFfi {
        OnboardingFindingFfi(issue: issue, endpoint: endpoint, context: context, purpose: .directoryQuery,
                             outcome: outcome, declaredCapability: .inbox, actions: [], observedRevision: 2)
    }
}

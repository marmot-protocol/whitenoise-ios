import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct DeveloperReportTests {
    @Test func messageReportCarriesOnlyTheUserReasonAndExplanation() throws {
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("22")))
        let text = try #require(DeveloperReportContent.text(
            kind: .message(reason: .impersonation, explanation: "  Pretending\nto be me  "),
            reportedAccountIdHex: hex("22").uppercased()
        ))

        #expect(text == """
        **User report**

        - **Reported user:** `\(npub)`
        - **Reason:** Impersonation
        - **Explanation:** Pretending to be me
        """)
    }

    @Test func blankExplanationIsOmittedAndLongOnesAreBounded() throws {
        let blank = try #require(DeveloperReportContent.text(
            kind: .message(reason: .spam, explanation: "   "),
            reportedAccountIdHex: hex("22")
        ))
        #expect(!blank.contains("Explanation:"))

        let long = String(repeating: "x", count: DeveloperReportContent.explanationLimit + 50)
        let bounded = try #require(DeveloperReportContent.text(
            kind: .message(reason: .other, explanation: long),
            reportedAccountIdHex: hex("22")
        ))
        #expect(bounded.hasSuffix(String(repeating: "x", count: DeveloperReportContent.explanationLimit) + "…"))
    }

    @Test func blockReportNamesOnlyTheUser() throws {
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("22")))
        let text = DeveloperReportContent.text(kind: .block, reportedAccountIdHex: hex("22"))
        #expect(text == "**Blocked user report**\n\n- **Blocked user:** `\(npub)`")
    }

    @Test func refusesAnAuthorThatIsNotAPublicKey() {
        #expect(DeveloperReportContent.text(kind: .block, reportedAccountIdHex: "not-a-key") == nil)
        #expect(DeveloperReportContent.text(kind: .block, reportedAccountIdHex: "") == nil)
    }

    @Test func onlySomeoneElsesLiveMessageCanBeReportedOrBlocked() {
        let me = hex("11")
        let other = hex("22")
        #expect(MessageModerationPolicy.isOtherAuthor(direction: "received", sender: other, myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "sent", sender: me, myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: me.uppercased(), myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: other, myAccountId: me, isDeleted: true))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: "", myAccountId: me, isDeleted: false))
    }

    @Test func reportOutcomeNamesEveryDestinationAndDisposition() {
        #expect(ReportPresentation.developerOutcome(.published) == "Sent to the White Noise team.")
        #expect(ReportPresentation.developerOutcome(.acceptedPending)
            == "Saved and waiting to send to the White Noise team.")
        #expect(ReportPresentation.developerOutcome(.completionUnknown)
            == "Saved; delivery to the White Noise team is pending confirmation.")
        let group = "Sent to the group."
        #expect(ReportPresentation.outcome(groupOutcome: group, developerDisposition: .acceptedPending)
            == "Sent to the group. Saved and waiting to send to the White Noise team.")
        #expect(ReportPresentation.outcome(groupOutcome: group, developerDisposition: nil) == group)
        #expect(ReportPresentation.outcome(groupOutcome: nil, developerDisposition: nil) == nil)
    }

    @Test func failedWhiteNoiseCopyKeepsTheGroupReportsRealStatus() {
        let failure = "Couldn't reach White Noise."
        #expect(ReportPresentation.developerFailure(groupOutcome: nil, failure: failure) == failure)
        for disposition in [SendAcceptDispositionFfi.published, .acceptedPending, .completionUnknown] {
            let summary = SendSummaryFfi(
                published: 0, messageIds: [], acceptDisposition: disposition, maintenanceDisposition: .ready
            )
            let group = ReportPresentation.outcome(summary)
            #expect(ReportPresentation.developerFailure(groupOutcome: group, failure: failure)
                == group + " The copy to White Noise couldn't be sent. Try again.")
        }
        let queued = ReportPresentation.outcome(SendSummaryFfi(
            published: 0, messageIds: [], acceptDisposition: .acceptedPending, maintenanceDisposition: .ready
        ))
        #expect(ReportPresentation.developerFailure(groupOutcome: queued, failure: failure)
            .hasPrefix("Saved and waiting to send."))
    }

    @MainActor
    @Test func deliveryReusesTheSupportChatAndReturnsTheSendDisposition() async throws {
        let harness = DeliveryHarness(existing: "support-group")
        harness.disposition = .completionUnknown
        let summary = try await harness.delivery.deliver("report", to: recipient)
        #expect(summary.acceptDisposition == .completionUnknown)
        #expect(harness.startedWith == ["support-group"])
        #expect(harness.sent == ["account-a/support-group/report"])
    }

    @MainActor
    @Test func profileSwitchDuringLookupNeverCreatesASupportChat() async {
        let harness = DeliveryHarness(existing: nil)
        harness.onLookup = { harness.scope = .init(accountRef: "account-b", runtimeGeneration: 1) }
        await #expect(throws: CancellationError.self) {
            _ = try await harness.delivery.deliver("report", to: recipient)
        }
        #expect(harness.startedWith.isEmpty)
        #expect(harness.sent.isEmpty)
    }

    @MainActor
    @Test func runtimeRestartAfterOpeningTheChatStopsTheSend() async {
        let harness = DeliveryHarness(existing: nil)
        harness.onStart = { harness.scope = .init(accountRef: "account-a", runtimeGeneration: 2) }
        await #expect(throws: CancellationError.self) {
            _ = try await harness.delivery.deliver("report", to: recipient)
        }
        #expect(harness.startedWith == [nil])
        #expect(harness.sent.isEmpty)
    }

    @MainActor
    @Test func missingSupportContactOrFailedStartIsUnavailable() async {
        let harness = DeliveryHarness(existing: nil)
        await #expect(throws: DeveloperReportDelivery.Failure.self) {
            _ = try await harness.delivery.deliver("report", to: nil)
        }
        harness.startOutcome = .failed(.missingSetup)
        await #expect(throws: DeveloperReportDelivery.Failure.self) {
            _ = try await harness.delivery.deliver("report", to: recipient)
        }
        #expect(harness.sent.isEmpty)
    }

    private var recipient: ResolvedRecipient {
        ResolvedRecipient(accountIdHex: hex("33"), memberRef: hex("33"), queriedNip05: nil)
    }

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }
}

@MainActor
private final class DeliveryHarness {
    var scope: DeveloperReportDelivery.Scope? = .init(accountRef: "account-a", runtimeGeneration: 1)
    let existing: String?
    var onLookup: () -> Void = {}
    var onStart: () -> Void = {}
    var startOutcome: DirectChatStarter.Outcome = .created(groupIdHex: "new-group")
    var disposition: SendAcceptDispositionFfi = .published
    private(set) var startedWith: [String?] = []
    private(set) var sent: [String] = []

    init(existing: String?) {
        self.existing = existing
    }

    var delivery: DeveloperReportDelivery {
        DeveloperReportDelivery(
            currentScope: { self.scope },
            existingSupportChat: { _, _ in
                await Task.yield()
                self.onLookup()
                return self.existing
            },
            startSupportChat: { _, existing in
                self.startedWith.append(existing)
                self.onStart()
                return existing.map { .opened(groupIdHex: $0) } ?? self.startOutcome
            },
            sendText: { accountRef, groupIdHex, text in
                self.sent.append("\(accountRef)/\(groupIdHex)/\(text)")
                return SendSummaryFfi(
                    published: 1,
                    messageIds: [],
                    acceptDisposition: self.disposition,
                    maintenanceDisposition: .ready
                )
            }
        )
    }
}

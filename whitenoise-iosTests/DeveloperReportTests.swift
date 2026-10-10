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

    @Test func reportOutcomeNamesEveryDestination() {
        let group = "Sent to the group."
        #expect(ReportPresentation.outcome(groupOutcome: group, sentToDeveloper: true)
            == "Sent to the group. Sent to the White Noise team.")
        #expect(ReportPresentation.outcome(groupOutcome: nil, sentToDeveloper: true) == "Sent to the White Noise team.")
        #expect(ReportPresentation.outcome(groupOutcome: group, sentToDeveloper: false) == group)
        #expect(ReportPresentation.outcome(groupOutcome: nil, sentToDeveloper: false) == nil)
    }

    private func hex(_ byte: String) -> String {
        String(repeating: byte, count: 32)
    }
}

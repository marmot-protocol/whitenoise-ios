import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct ModerationReportTests {
    @Test func onlySomeoneElsesLiveMessageCanBeReportedOrBlocked() {
        let me = hex("11")
        let other = hex("22")
        #expect(MessageModerationPolicy.isOtherAuthor(direction: "received", sender: other, myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "sent", sender: me, myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: me.uppercased(), myAccountId: me, isDeleted: false))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: other, myAccountId: me, isDeleted: true))
        #expect(!MessageModerationPolicy.isOtherAuthor(direction: "received", sender: "", myAccountId: me, isDeleted: false))
    }

    @Test func flavorReportsKeysDecodeToTheirPublicKeys() throws {
        let production = try #require(ModerationReportBuildConfig.current(
            rawPubkey: "npub1cwlgauttl8fr3va4gy0sawq62sjt8hrz4wc200pvkrz6fjdj7tlseeq8rl"
        ))
        let staging = try #require(ModerationReportBuildConfig.current(
            rawPubkey: " npub1vnlg8lzm48f3awy0lqqhff66rzaxxyqf85twvyrnj6ycjtfy47rsk52fml\n"
        ))
        #expect(Hex.is32Bytes(production.recipientPubkeyHex))
        #expect(Hex.is32Bytes(staging.recipientPubkeyHex))
        #expect(production.recipientPubkeyHex != staging.recipientPubkeyHex)
        #expect(NostrProfileReference.npub(fromAccountIdHex: production.recipientPubkeyHex)
            == "npub1cwlgauttl8fr3va4gy0sawq62sjt8hrz4wc200pvkrz6fjdj7tlseeq8rl")
        #expect(production.relays == AppContainerConfig.seedRelays)
        #expect(production.ffi.recipientPubkey == production.recipientPubkeyHex)
    }

    @Test func missingOrMalformedReportsKeyLeavesReportingUnconfigured() throws {
        #expect(ModerationReportBuildConfig.current(rawPubkey: nil) == nil)
        #expect(ModerationReportBuildConfig.current(rawPubkey: "") == nil)
        #expect(ModerationReportBuildConfig.current(rawPubkey: "$(WHITENOISE_MODERATION_REPORT_PUBKEY)") == nil)
        #expect(ModerationReportBuildConfig.current(rawPubkey: "npub1notvalid") == nil)
        let fromHex = try #require(ModerationReportBuildConfig.current(rawPubkey: hex("AB")))
        #expect(fromHex.recipientPubkeyHex == hex("ab"))
    }

    @Test func moderationReportErrorsHaveReadableMessages() {
        #expect(UserFacingError.message(for: MarmotKitError.ModerationReportRateLimited)
            == "You’ve sent a lot of reports recently. Try again later.")
        #expect(UserFacingError.message(for: MarmotKitError.CannotReportSelf) == "You can’t report yourself.")
        #expect(UserFacingError.message(for: MarmotKitError.InvalidReportedPublicKey) == "This person can’t be reported.")
        let unavailable = "Reporting to White Noise isn’t available in this version of the app."
        #expect(UserFacingError.message(for: MarmotKitError.ModerationReportingNotConfigured) == unavailable)
        #expect(UserFacingError.message(for: MarmotKitError.InvalidModerationReportConfig(details: "bad relay"))
            == unavailable)
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
        let failure = "You’ve sent a lot of reports recently. Try again later."
        #expect(ReportPresentation.developerFailure(groupOutcome: nil, failure: failure) == failure)
        for disposition in [SendAcceptDispositionFfi.published, .acceptedPending, .completionUnknown] {
            let summary = SendSummaryFfi(
                published: 0, messageIds: [], acceptDisposition: disposition, maintenanceDisposition: .ready
            )
            let group = ReportPresentation.outcome(summary)
            #expect(ReportPresentation.developerFailure(groupOutcome: group, failure: failure)
                == group + " The copy to White Noise couldn't be sent. Try again.")
        }
    }

    @Test func retryFinishesWhatTheFirstSubmitCommittedToEvenAfterDeletion() {
        // A fresh submit follows live eligibility.
        #expect(ReportSubmissionPlan.plan(reportsToGroup: true, reportsToDeveloper: true,
                                          groupOutcomeRecorded: false, committedToDeveloper: nil)
            == ReportSubmissionPlan(toGroup: true, toDeveloper: true))
        #expect(ReportSubmissionPlan.plan(reportsToGroup: false, reportsToDeveloper: false,
                                          groupOutcomeRecorded: false, committedToDeveloper: nil) == nil)
        // The group has the report and the copy failed; the message is now deleted,
        // so live eligibility is gone, but the committed copy can still be retried.
        #expect(ReportSubmissionPlan.plan(reportsToGroup: false, reportsToDeveloper: false,
                                          groupOutcomeRecorded: true, committedToDeveloper: true)
            == ReportSubmissionPlan(toGroup: false, toDeveloper: true))
        // A group-only report that already succeeded has nothing left to send.
        #expect(ReportSubmissionPlan.plan(reportsToGroup: true, reportsToDeveloper: false,
                                          groupOutcomeRecorded: true, committedToDeveloper: false) == nil)
    }

    @Test func blockAndReportWaitsOutAnUncertainBlockAndNeverReportsForAnotherProfile() {
        #expect(BlockReportFollowUp.after(blockConfirmed: true, retryPending: false, sameAccount: true) == .send)
        #expect(BlockReportFollowUp.after(blockConfirmed: false, retryPending: true, sameAccount: true) == .wait)
        #expect(BlockReportFollowUp.after(blockConfirmed: false, retryPending: false, sameAccount: true) == .drop)
        #expect(BlockReportFollowUp.after(blockConfirmed: true, retryPending: false, sameAccount: false) == .drop)
    }
}

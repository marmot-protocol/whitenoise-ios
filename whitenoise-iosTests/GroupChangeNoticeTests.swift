import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct GroupChangeNoticeTests {
    private func event(kind: String = "group_profile", outcome: String) -> MarmotEventFfi {
        .groupChangeSuperseded(accountIdHex: "account", accountLabel: "private profile",
                               groupIdHex: "group", commitIdHex: "commit", kind: kind,
                               outcome: outcome, reason: "private backend detail")
    }

    @Test func automaticReissueNeedsNoNotice() {
        #expect(GroupChangeNotice.toast(for: event(outcome: "reissued")) == nil)
        #expect(GroupChangeNotice.toast(for: .agentStreamActivity(accountIdHex: "account", accountLabel: "profile")) == nil)
    }

    @Test(arguments: ["conflict", "already_satisfied", "reinvite_required", "abandoned", "not_member", "future_outcome"])
    func unresolvedChangesSurfaceWithoutBackendDetails(outcome: String) throws {
        let toast = try #require(GroupChangeNotice.toast(for: event(outcome: outcome)))
        #expect(toast.style == .warning)
        #expect(toast.message?.isEmpty == false)
        #expect(!toast.title.contains("private"))
        #expect(toast.message?.contains("private") == false)
        #expect(toast.diagnostic == nil)
    }

    @Test func recoveryInstructionsDistinguishInvitationsAndRemovals() {
        let invitation = GroupChangeNotice.toast(for: event(kind: "invite", outcome: "reinvite_required"))
        let removal = GroupChangeNotice.toast(for: event(kind: "remove_members", outcome: "conflict"))
        #expect(invitation?.message != removal?.message)
    }

    @Test func diagnosticsIncludeRecoveryOutcome() {
        let text = DiagnosticsView.diagnosticText(for: event(outcome: "conflict"))
        #expect(text.contains("group_profile"))
        #expect(text.contains("conflict"))
        #expect(text.contains("superseded"))
    }
}

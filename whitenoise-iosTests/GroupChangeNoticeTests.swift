import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct GroupChangeNoticeTests {
    private func quarantine(
        _ reason: AppGroupHydrationQuarantineReasonFfi,
        account: String = "account",
        group: String = "group"
    ) -> MarmotEventFfi {
        .groupEvent(accountIdHex: account, accountLabel: "private profile", groupIdHex: group,
                    event: .groupHydrationQuarantined(reason: reason))
    }

    @Test func onlyAFailedRewindRestoreTellsTheUserToRestart() {
        let restart = GroupChangeNotice.toast(for: quarantine(.rewindRestoreFailed))
        #expect(restart?.style == .warning)
        #expect(restart?.message?.isEmpty == false)
        for reason in [AppGroupHydrationQuarantineReasonFfi.openMlsLoadFailed, .openMlsGroupMissing,
                       .memberValidationFailed, .groupRecordLoadFailed, .pendingCommitRecoveryFailed] {
            #expect(GroupChangeNotice.toast(for: quarantine(reason)) == nil)
        }
    }

    @Test func eachAccountsFailedRewindRestoreOfAGroupIsAnnouncedOnce() {
        var announcements = RefusedIntentAnnouncements()
        let admitted = [
            announcements.admit(quarantine(.rewindRestoreFailed, account: "alice", group: "a")),
            announcements.admit(quarantine(.rewindRestoreFailed, account: "alice", group: "a")),
            announcements.admit(quarantine(.rewindRestoreFailed, account: "alice", group: "b")),
            announcements.admit(quarantine(.rewindRestoreFailed, account: "bob", group: "a")),
            announcements.admit(quarantine(.rewindRestoreFailed, account: "bob", group: "a")),
        ]
        #expect(admitted == [true, false, true, true, false])
    }

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

    private func refusal(
        id: String = "intent",
        kind: String,
        reason: String,
        artifact: OversizedArtifactFfi? = nil,
        sizeClass: EventSizeClassFfi? = nil
    ) -> MarmotEventFfi {
        .groupEvent(accountIdHex: "account", accountLabel: "private profile", groupIdHex: "group",
                    event: .queuedIntentRefused(intentIdHex: id, intentKind: kind, reason: reason,
                                                artifact: artifact, sizeClass: sizeClass))
    }

    @Test func oversizedQueuedChangesSayWhichRelaysRefusedThem() {
        let generic = GroupChangeNotice.toast(for: refusal(kind: "invite", reason: "future_reason"))
        let commit = GroupChangeNotice.toast(
            for: refusal(kind: "remove_members", reason: "event_too_large", artifact: .commit, sizeClass: .over4Mib))
        let welcome = GroupChangeNotice.toast(
            for: refusal(kind: "invite", reason: "event_too_large", artifact: .welcome, sizeClass: .from2To4Mib))
        let unspecified = GroupChangeNotice.toast(for: refusal(kind: "invite", reason: "event_too_large"))
        #expect(commit?.message == UserFacingError.eventTooLargeMessage(.commit))
        #expect(welcome?.message == UserFacingError.eventTooLargeMessage(.welcome))
        #expect(unspecified?.message == commit?.message)
        #expect(Set([generic?.message, commit?.message, welcome?.message]).count == 3)
    }

    @Test func diagnosticsIncludeOversizedRefusalDetails() {
        let text = DiagnosticsView.diagnosticText(
            for: refusal(kind: "invite", reason: "event_too_large", artifact: .welcome, sizeClass: .from2To4Mib))
        #expect(text.contains("event_too_large"))
        #expect(text.contains("welcome"))
        #expect(text.contains("from2To4Mib"))
    }

    @Test(arguments: ["invite", "remove_members", "update_group_data", "leave", "disband", "app_message", "future_kind"])
    func droppedQueuedChangesAlwaysTellTheUser(kind: String) throws {
        let toast = try #require(GroupChangeNotice.toast(for: refusal(kind: kind, reason: "future_reason")))
        #expect(toast.style == .warning)
        #expect(toast.message?.isEmpty == false)
        #expect(!toast.title.contains("private"))
        #expect(toast.message?.contains("future_reason") == false)
        #expect(toast.diagnostic == nil)
    }

    @Test func droppedChangesNameWhatWasLostAndWhy() {
        let invite = GroupChangeNotice.toast(for: refusal(kind: "invite", reason: "not_group_admin"))
        let removal = GroupChangeNotice.toast(for: refusal(kind: "remove_members", reason: "not_group_admin"))
        let notMember = GroupChangeNotice.toast(for: refusal(kind: "invite", reason: "not_a_member"))
        #expect(invite?.title != removal?.title)
        #expect(invite?.message == removal?.message)
        #expect(invite?.message != notMember?.message)
    }

    @Test func eachDroppedChangeIsAnnouncedOnce() {
        var announcements = RefusedIntentAnnouncements()
        let admitted = [
            announcements.admit(refusal(id: "a", kind: "invite", reason: "not_group_admin")),
            announcements.admit(refusal(id: "a", kind: "invite", reason: "not_group_admin")),
            announcements.admit(refusal(id: "b", kind: "invite", reason: "not_group_admin")),
            announcements.admit(event(outcome: "conflict")),
            announcements.admit(event(outcome: "conflict")),
        ]
        #expect(admitted == [true, false, true, true, true])
    }

    @Test func announcementMemoryStaysBounded() {
        var announcements = RefusedIntentAnnouncements()
        var firstPass: [Bool] = []
        for index in 0..<200 {
            firstPass.append(announcements.admit(refusal(id: "intent-\(index)", kind: "invite", reason: "x")))
        }
        #expect(firstPass.allSatisfy { $0 })
        // The oldest ids age out rather than growing without limit.
        let oldest = announcements.admit(refusal(id: "intent-0", kind: "invite", reason: "x"))
        let newest = announcements.admit(refusal(id: "intent-199", kind: "invite", reason: "x"))
        #expect(oldest)
        #expect(!newest)
    }
}

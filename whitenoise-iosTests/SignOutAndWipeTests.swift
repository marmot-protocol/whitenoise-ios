import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// Pure decisions behind the destructive Sign Out & Wipe: the engine-outcome
/// report projection and the suspension-safety gate
/// that decides whether the teardown may begin.
struct SignOutAndWipeTests {

    @Test func readyRootRoutesToProfileSelectionWithoutAnActiveAccount() {
        #expect(RootPresentation.resolve(phase: .ready, activeAccountRef: nil) == .profileSelection)
        #expect(RootPresentation.resolve(phase: .ready, activeAccountRef: "profile-a") == .main)
        #expect(RootPresentation.resolve(phase: .onboarding, activeAccountRef: nil) == .onboarding)
    }

    // MARK: - Report projection

    private func outcome(
        groupsLeft: UInt32 = 0,
        groupLeaveFailures: [GroupLeaveFailureFfi] = [],
        keyPackagesDeleted: UInt32 = 0,
        keyPackageFailures: [RelayFailureFfi] = [],
        localCleanupCompleted: Bool = true,
        localCleanupReason: String? = nil
    ) -> WipeOutcomeFfi {
        WipeOutcomeFfi(
            groupsLeft: groupsLeft,
            groupLeaveFailures: groupLeaveFailures,
            keyPackagesDeleted: keyPackagesDeleted,
            keyPackageFailures: keyPackageFailures,
            localCleanup: LocalCleanupReportFfi(completed: localCleanupCompleted, reason: localCleanupReason)
        )
    }

    @Test func cleanWipeMapsToCleanReportWithThreeStagesInEngineOrder() {
        let report = WipeReportProjection.report(from: outcome(groupsLeft: 3, keyPackagesDeleted: 2))
        #expect(report.clean)
        #expect(report.issueCount == 0)
        #expect(report.stages.map(\.stage) == [.leavingGroups, .deletingKeyPackages, .wipingLocalData])
        #expect(report.stages[0].completedCount == 3)
        #expect(report.stages[1].completedCount == 2)
        #expect(report.stages[2].completedCount == nil)
        #expect(report.stages.allSatisfy { !$0.hasIssues })
    }

    @Test func groupLeaveAndKeyPackageFailuresAreCountedWithShortenedSubjects() {
        let longGroupId = String(repeating: "a", count: 64)
        let longEventId = String(repeating: "b", count: 64)
        let report = WipeReportProjection.report(from: outcome(
            groupsLeft: 1,
            groupLeaveFailures: [GroupLeaveFailureFfi(groupIdHex: longGroupId, reason: "relay unreachable")],
            keyPackagesDeleted: 0,
            keyPackageFailures: [RelayFailureFfi(eventIdHex: longEventId, reason: "timeout")]
        ))
        #expect(!report.clean)
        #expect(report.issueCount == 2)

        let groups = report.stages[0]
        #expect(groups.hasIssues)
        #expect(groups.completedCount == 1)
        #expect(groups.failures.first?.subject == "aaaaaaaaaaaa…")
        #expect(groups.failures.first?.reason == "relay unreachable")

        let keyPackages = report.stages[1]
        #expect(keyPackages.failures.first?.subject == "bbbbbbbbbbbb…")
        #expect(keyPackages.failures.first?.reason == "timeout")
    }

    @Test func shortSubjectLeavesShortIdentifiersUntouched() {
        #expect(WipeReportProjection.shortSubject("abc123") == "abc123")
        #expect(WipeReportProjection.shortSubject("0123456789ab") == "0123456789ab")
        #expect(WipeReportProjection.shortSubject("0123456789abc") == "0123456789ab…")
    }

    @Test func incompleteLocalCleanupBecomesAWipingLocalDataFailure() {
        let report = WipeReportProjection.report(from: outcome(
            localCleanupCompleted: false,
            localCleanupReason: "  disk full  "
        ))
        #expect(!report.clean)
        let local = report.stages[2]
        #expect(local.hasIssues)
        #expect(local.failures.count == 1)
        #expect(local.failures.first?.subject == nil)
        #expect(local.failures.first?.reason == "disk full")
    }

    @Test func incompleteLocalCleanupWithNoReasonStillReportsAFailure() {
        let report = WipeReportProjection.report(from: outcome(localCleanupCompleted: false, localCleanupReason: nil))
        #expect(report.stages[2].hasIssues)
        #expect(report.stages[2].failures.first?.reason == "")
    }

    @Test func swiftCleanupFailuresMakeAnOtherwiseCleanWipeReportIncomplete() {
        let report = WipeReportProjection.report(
            from: outcome(),
            additionalLocalFailures: [
                WipeFailureItem(subject: nil, reason: "notification residue"),
                WipeFailureItem(subject: nil, reason: "media residue"),
            ]
        )

        #expect(!report.clean)
        #expect(report.stages[2].failures.map(\.reason) == [
            "notification residue",
            "media residue",
        ])
    }

    @Test func pathologicallyLongReasonIsBounded() {
        let huge = String(repeating: "x", count: WipeReportProjection.maxReasonLength + 50)
        let bounded = WipeReportProjection.boundedReason(huge)
        #expect(bounded.count == WipeReportProjection.maxReasonLength + 1) // + the ellipsis
        #expect(bounded.hasSuffix("…"))
    }

    // MARK: - Suspension-safety gate

    @Test func wipeMayBeginOnlyWithALiveForegroundRuntime() {
        #expect(DestructiveWipeGate.canBegin(
            isReady: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
    }

    @Test func normalSignOutUsesTheSameForegroundRuntimeGateAsWipe() {
        #expect(AccountExitGate.canBegin(
            isReady: true,
            isAppSceneActive: true,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
        #expect(!AccountExitGate.canBegin(
            isReady: true,
            isAppSceneActive: false,
            runtimeSuspendedForBackground: false,
            isRuntimeSuspending: false,
            hasRuntimeClient: true
        ))
    }

    @Test func wipeIsBlockedWhileSuspendedSuspendingBackgroundedOrClientReleased() {
        // Runtime released for background suspension.
        #expect(!DestructiveWipeGate.canBegin(
            isReady: true, isAppSceneActive: true,
            runtimeSuspendedForBackground: true, isRuntimeSuspending: false, hasRuntimeClient: false
        ))
        // Mid-suspension.
        #expect(!DestructiveWipeGate.canBegin(
            isReady: true, isAppSceneActive: true,
            runtimeSuspendedForBackground: false, isRuntimeSuspending: true, hasRuntimeClient: true
        ))
        // Scene not active (backgrounded/inactive).
        #expect(!DestructiveWipeGate.canBegin(
            isReady: true, isAppSceneActive: false,
            runtimeSuspendedForBackground: false, isRuntimeSuspending: false, hasRuntimeClient: true
        ))
        // No live client handle.
        #expect(!DestructiveWipeGate.canBegin(
            isReady: true, isAppSceneActive: true,
            runtimeSuspendedForBackground: false, isRuntimeSuspending: false, hasRuntimeClient: false
        ))
        // Not in the ready phase (bootstrapping / onboarding / failed).
        #expect(!DestructiveWipeGate.canBegin(
            isReady: false, isAppSceneActive: true,
            runtimeSuspendedForBackground: false, isRuntimeSuspending: false, hasRuntimeClient: true
        ))
    }
}

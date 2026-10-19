import Foundation
import MarmotKit

/// The stages of the destructive Sign Out & Wipe, in the order the engine runs
/// them inside `Marmot.signOutAndWipe`. The FFI is a single async call that
/// reports every stage only in its final `WipeOutcomeFfi`, so the UI renders
/// these as an indeterminate staged display while in flight and marks them from
/// the outcome afterwards.
nonisolated enum WipeStage: Equatable, Hashable {
    case leavingGroups
    case deletingKeyPackages
    case wipingLocalData
}

/// One best-effort failure inside a wipe stage. `subject` is a shortened
/// identifier of the affected group / relay event (`nil` for the local-cleanup
/// stage, which has no per-item subject); `reason` is the engine's diagnostic.
nonisolated struct WipeFailureItem: Equatable {
    let subject: String?
    let reason: String
}

/// Per-stage result mapped from the engine outcome for the wipe outcome sheet.
nonisolated struct WipeStageReport: Equatable {
    let stage: WipeStage
    /// How many items the stage completed (groups left, key packages deleted).
    /// `nil` for `.wipingLocalData`, which is all-or-nothing.
    let completedCount: Int?
    let failures: [WipeFailureItem]

    var hasIssues: Bool { !failures.isEmpty }
}

/// UI model of a finished Sign Out & Wipe. A `clean` wipe just navigates back; a report
/// with issues drives the outcome sheet. The account ref is invalid by the time
/// this exists, so the sheet renders only this snapshot and never reaches back
/// into the FFI.
nonisolated struct WipeReport: Equatable {
    let stages: [WipeStageReport]

    var issueCount: Int { stages.reduce(0) { $0 + $1.failures.count } }
    var clean: Bool { issueCount == 0 }
}

/// Maps the engine's `WipeOutcomeFfi` to the pure `WipeReport` UI model. Stages
/// map 1:1 to the outcome fields, in engine execution order.
nonisolated enum WipeReportProjection {
    /// Engine failure reasons are shown verbatim in the outcome sheet; bound
    /// them so a pathologically long diagnostic can't blow up layout.
    static let maxReasonLength = 200

    static func report(
        from outcome: WipeOutcomeFfi,
        additionalLocalFailures: [WipeFailureItem] = []
    ) -> WipeReport {
        let engineLocalFailures = outcome.localCleanup.completed
            ? []
            : [WipeFailureItem(subject: nil, reason: boundedReason(outcome.localCleanup.reason ?? ""))]
        let localFailures = engineLocalFailures + additionalLocalFailures.map {
            WipeFailureItem(subject: $0.subject, reason: boundedReason($0.reason))
        }
        return WipeReport(stages: [
            WipeStageReport(
                stage: .leavingGroups,
                completedCount: Int(outcome.groupsLeft),
                failures: outcome.groupLeaveFailures.map {
                    WipeFailureItem(subject: shortSubject($0.groupIdHex), reason: boundedReason($0.reason))
                }
            ),
            WipeStageReport(
                stage: .deletingKeyPackages,
                completedCount: Int(outcome.keyPackagesDeleted),
                failures: outcome.keyPackageFailures.map {
                    WipeFailureItem(subject: shortSubject($0.eventIdHex), reason: boundedReason($0.reason))
                }
            ),
            WipeStageReport(
                stage: .wipingLocalData,
                completedCount: nil,
                failures: localFailures
            )
        ])
    }

    /// Shortens a hex identifier (group id, relay event id) for a failure row.
    /// Full ids are 64 chars of noise; the first 12 are plenty to correlate
    /// against logs.
    static func shortSubject(_ hex: String) -> String {
        hex.count <= 12 ? hex : String(hex.prefix(12)) + "…"
    }

    static func boundedReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxReasonLength else { return trimmed }
        return String(trimmed.prefix(maxReasonLength)) + "…"
    }
}

/// Decides whether the destructive Sign Out & Wipe may begin. A destructive
/// teardown must never start against a released or mid-suspension runtime — it
/// would reopen the App Group SQLite store after suspension deliberately closed
/// it. This is the union of the two strongest existing guards: the settings-read
/// runtime gate (scene active, not suspended/suspending, live client) plus the
/// `.ready` phase gate the audit-log delete uses. Pure so the gate is testable.
enum AccountExitGate {
    static func canBegin(
        isReady: Bool,
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        isReady
            && isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && hasRuntimeClient
    }
}

enum DestructiveWipeGate {
    static func canBegin(
        isReady: Bool,
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        AccountExitGate.canBegin(
            isReady: isReady,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: hasRuntimeClient
        )
    }
}

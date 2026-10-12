import Foundation
import MarmotKit

/// Who may be reported to, or blocked from, a message's long-press menu.
nonisolated enum MessageModerationPolicy {
    /// Someone else's live message with a valid author key. Your own messages
    /// and deleted ones have nothing to report or block.
    static func isOtherAuthor(
        direction: String,
        sender: String,
        myAccountId: String?,
        isDeleted: Bool
    ) -> Bool {
        guard !isDeleted, direction != "sent",
              let author = Hex.normalized32Bytes(sender) else { return false }
        return author != Hex.normalized32Bytes(myAccountId)
    }
}

/// Private reports to the White Noise moderation team (IPF) through MDK's
/// gift-wrapped NIP-56 reports. MDK sends only the reported key, the reason
/// and the reporter's optional explanation, to this build flavor's reports key
/// and relays; queued reports retry on catch-up and must not be resubmitted.
/// Additive to in-group `reportMessage`, which stays the admins' path.
@MainActor
enum ModerationReportSender {
    static func isAvailable(_ appState: AppState?) -> Bool {
        appState?.moderationReportingAvailable == true
    }

    static func submit(
        reportedAccountIdHex: String,
        reason: ReportReasonFfi,
        explanation: String,
        origin: ModerationReportOriginFfi,
        accountRef: String,
        using appState: AppState
    ) async throws -> ModerationReportOutcomeFfi {
        try await appState.currentMarmotClient().submitModerationReport(
            accountRef: accountRef,
            reportedPubkey: reportedAccountIdHex,
            reason: reason,
            explanation: explanation,
            origin: origin
        )
    }

    /// Runs after a confirmed block. The block already succeeded, so a failed
    /// report surfaces as a toast rather than undoing anything. Block and
    /// Report has no user-chosen reason, so it reports `other`.
    static func sendBlockReport(reportedAccountIdHex: String, accountRef: String, using appState: AppState) async {
        do {
            let outcome = try await submit(
                reportedAccountIdHex: reportedAccountIdHex,
                reason: .other,
                explanation: "",
                origin: .blockAndReport,
                accountRef: accountRef,
                using: appState
            )
            guard appState.activeAccountRef == accountRef else { return }
            appState.present(.success(
                L10n.string("Report submitted"),
                message: ReportPresentation.developerOutcome(outcome.acceptDisposition)
            ))
        } catch is CancellationError {
        } catch {
            guard appState.activeAccountRef == accountRef else { return }
            appState.present(.error(
                L10n.string("Report not sent"),
                message: UserFacingError.message(for: error)
            ))
        }
    }
}

import MarmotKit
import SwiftUI

/// Localized wording for MDK's "history may be incomplete" notices. Notices
/// carry no relay, message or key identities; keep them out of analytics.
nonisolated enum HistoryNoticePresentation {
    static func message(for cause: HistoryNoticeCauseFfi) -> String {
        switch cause {
        case .deliveryLoss, .notificationLoss:
            L10n.string("Some messages may not have reached this device.")
        case .epochGap:
            L10n.string("Some messages in this chat may be missing.")
        case .incrementalHistory:
            L10n.string("Messages from while you were away may be incomplete.")
        case .explicitRepair:
            L10n.string("History repair couldn’t confirm that every message was restored.")
        case .knownEvent:
            L10n.string("A message couldn’t be retrieved.")
        case .maintenanceBoundary:
            L10n.string("Messages from around when you joined may be incomplete.")
        }
    }

    /// Group notices without a matching account-list entry still come from an epoch gap.
    static func groupMessage(noticeIDs: [String], notices: [HistoryNoticeFfi]) -> String {
        let cause = notices.first { noticeIDs.contains($0.noticeId) }?.cause ?? .epochGap
        return message(for: cause)
    }
}

/// The active account's durable history notices. MDK owns the state; this
/// mirrors it for presentation and routes the user's dismissal back.
@MainActor @Observable
final class HistoryNoticeStore {
    private(set) var notices: [HistoryNoticeFfi] = []
    private(set) var dismissing: Set<String> = []
    private var accountRef: String?
    private var runtimeGeneration: Int?
    private var readTicket = UUID()

    var accountNotices: [HistoryNoticeFfi] { notices.filter { $0.groupIdHex == nil } }

    func refresh(using appState: AppState) async {
        guard appState.canUseRuntimeForForegroundWork, let account = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else {
            clear()
            return
        }
        if accountRef != account || runtimeGeneration != appState.runtimeGeneration {
            clear()
            accountRef = account
            runtimeGeneration = appState.runtimeGeneration
        }
        let ticket = UUID()
        readTicket = ticket
        guard let next = try? await client.historyNotices(accountRef: account),
              readTicket == ticket, matches(appState) else { return }
        notices = next
    }

    /// Dismisses each occurrence. A stale id means the list moved on, so it re-reads.
    func dismiss(_ noticeIDs: [String], using appState: AppState) async -> Bool {
        guard matches(appState), let account = accountRef, !noticeIDs.isEmpty,
              dismissing.isDisjoint(with: noticeIDs) else { return false }
        dismissing.formUnion(noticeIDs)
        defer { dismissing.subtract(noticeIDs) }
        var allDismissed = true
        do {
            let lease = try appState.runtimeLifecycle.beginForegroundRuntimeMutation()
            defer { appState.runtimeLifecycle.endForegroundRuntimeMutation(lease) }
            for id in noticeIDs {
                let dismissed = try await lease.client.dismissHistoryNotice(accountRef: account, noticeId: id)
                allDismissed = allDismissed && dismissed
            }
        } catch {
            allDismissed = false
            appState.present(UserFacingError.toast(title: L10n.string("Couldn’t dismiss notice"), error: error))
        }
        await refresh(using: appState)
        return allDismissed
    }

    func clear() {
        notices = []
        accountRef = nil
        runtimeGeneration = nil
        readTicket = UUID()
    }

    private func matches(_ appState: AppState) -> Bool {
        appState.canUseRuntimeForForegroundWork && appState.activeAccountRef == accountRef
            && appState.runtimeGeneration == runtimeGeneration
    }
}

/// One "history may be incomplete" banner with its dismissal.
struct HistoryNoticeBanner: View {
    let message: String
    let isDismissing: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("History may be incomplete")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .disabled(isDismissing)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

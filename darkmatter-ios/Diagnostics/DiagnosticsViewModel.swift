import Foundation
import MarmotKit

/// Screen store for `DiagnosticsView`: owns the streamed log entries + the
/// send-to-self flow, so the view is pure rendering. The view keeps the
/// `.task(id: runtimeGeneration)` that owns the stream's lifecycle and calls
/// `runEventStream`; the tested `DiagnosticsView.diagnosticText` static stays on
/// the view and is called here. Marmot reads go through the async
/// `currentMarmotClient()` wrapper (FFI-guard). `AppState` is passed in.
@MainActor
@Observable
final class DiagnosticsViewModel {
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
    }

    var entries: [LogEntry] = []
    var streaming = false
    var sendingToSelf = false

    /// Body of the view's `.task(id: runtimeGeneration)` — the view still owns
    /// the task lifecycle (rebinding when the runtime generation changes); this
    /// just provides the cancellable stream loop.
    func runEventStream(using appState: AppState) async {
        streaming = true
        defer { streaming = false }
        guard let client = try? appState.currentMarmotClient() else { return }
        let sub = client.subscribeEvents()
        for await event in SubscriptionDriver.events(sub) {
            append(DiagnosticsView.diagnosticText(for: event))
        }
    }

    func clear() {
        entries.removeAll()
    }

    func append(_ text: String) {
        entries.append(LogEntry(timestamp: Date(), text: text))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    func sendToSelf(using appState: AppState) async {
        guard !sendingToSelf, let accountRef = appState.activeAccountRef else { return }
        sendingToSelf = true
        defer { sendingToSelf = false }

        do {
            let client = try appState.currentMarmotClient()
            let groupId = try await diagnosticGroupId(accountRef: accountRef, using: appState)
            _ = try await client.sendText(
                accountRef: accountRef,
                groupIdHex: groupId,
                text: DiagnosticSelfSend.pingText(now: Date())
            )
            append("sent ping to self in \(IdentityFormatter.short(groupId))")
        } catch {
            append("send-to-self failed: \(error.localizedDescription)")
        }
    }

    private func diagnosticGroupId(accountRef: String, using appState: AppState) async throws -> String {
        let client = try appState.currentMarmotClient()
        let rows = try await client.chatList(
            accountRef: accountRef,
            includeArchived: true
        )
        if let row = DiagnosticSelfSend.reusableGroup(
            accountRef: accountRef,
            rows: rows
        ) {
            try await archiveDiagnosticGroupIfNeeded(row, accountRef: accountRef, using: appState)
            return row.groupIdHex
        }

        let groupId = try await client.createGroup(
            accountRef: accountRef,
            name: DiagnosticSelfSend.groupName,
            memberRefs: [],
            description: nil
        )
        DiagnosticSelfSend.remember(groupIdHex: groupId, accountRef: accountRef)
        _ = try await client.setGroupArchived(
            accountRef: accountRef,
            groupIdHex: groupId,
            archived: true
        )
        return groupId
    }

    private func archiveDiagnosticGroupIfNeeded(_ row: ChatListRowFfi, accountRef: String, using appState: AppState) async throws {
        guard !row.archived else { return }
        let client = try appState.currentMarmotClient()
        _ = try await client.setGroupArchived(
            accountRef: accountRef,
            groupIdHex: row.groupIdHex,
            archived: true
        )
    }
}

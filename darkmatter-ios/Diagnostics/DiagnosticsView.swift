import SwiftUI
import MarmotKit

/// Developer-facing scratchpad. Lives behind the "Show diagnostics" toggle
/// in Settings. Streams the top-level event firehose into a scrollable log.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [LogEntry] = []
    @State private var streaming = false
    @State private var sendingToSelf = false

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await sendToSelf() }
                } label: {
                    Label("Send to self", systemImage: "paperplane.fill")
                }
                .buttonStyle(.bordered)
                .disabled(sendingToSelf || appState.activeAccountRef == nil)

                Button {
                    entries.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: streaming ? "dot.radiowaves.left.and.right" : "circle.dotted")
                        .foregroundStyle(streaming ? .green : .secondary)
                        .symbolEffect(.variableColor.iterative, isActive: streaming)
                    Text(streaming ? L10n.string("Live") : L10n.string("Idle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: entries.count) { _, _ in
                    if let last = entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.runtimeGeneration) {
            streaming = true
            defer { streaming = false }
            let sub = appState.marmot.subscribeEvents()
            for await event in SubscriptionDriver.events(sub) {
                append(Self.diagnosticText(for: event))
            }
        }
    }

    private func append(_ text: String) {
        entries.append(LogEntry(timestamp: Date(), text: text))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    static func diagnosticText(for event: MarmotEventFfi) -> String {
        switch event {
        case .groupJoined(_, let label, let groupIdHex):
            return "[\(label)] joined group \(IdentityFormatter.short(groupIdHex))"
        case .groupStateUpdated(_, let label, let groupIdHex):
            return "[\(label)] group state ↺ \(IdentityFormatter.short(groupIdHex))"
        case .messageReceived(let received):
            return "[\(received.accountLabel)] msg from \(IdentityFormatter.short(received.message.sender)): \(plaintextSummary(received.message.plaintext))"
        case .projectionUpdated(let update):
            return "[\(update.accountLabel)] projection \(IdentityFormatter.short(update.update.groupIdHex))"
        case .groupEvent(_, let label, let groupIdHex, let event):
            return "[\(label)] group event \(groupEventLabel(event)) \(IdentityFormatter.short(groupIdHex))"
        case .accountError(_, let label, let message):
            return "[\(label)] error: \(message)"
        case .agentStreamActivity(_, let label):
            return "[\(label)] agent stream activity"
        }
    }

    private static func plaintextSummary(_ plaintext: String) -> String {
        plaintext.isEmpty ? "(empty)" : "(\(plaintext.count) chars)"
    }

    private static func groupEventLabel(_ event: GroupEventKindFfi) -> String {
        switch event {
        case .groupCreated:
            return "created"
        case .groupJoined:
            return "joined"
        case .messageReceived:
            return "message"
        case .appMessageInvalidated:
            return "message invalidated"
        case .groupStateChanged:
            return "state changed"
        case .groupHydrationQuarantined:
            return "hydration quarantined"
        case .epochChanged:
            return "epoch changed"
        case .forkRecovered:
            return "fork recovered"
        case .commitRolledBack:
            return "commit rolled back"
        case .groupUnrecoverable:
            return "unrecoverable"
        case .pendingCommitRecovered:
            return "pending commit recovered"
        case .groupHydrationRecovered:
            return "hydration recovered"
        }
    }

    @MainActor
    private func sendToSelf() async {
        guard !sendingToSelf, let accountRef = appState.activeAccountRef else { return }
        sendingToSelf = true
        defer { sendingToSelf = false }

        do {
            let groupId = try await diagnosticGroupId(accountRef: accountRef)
            _ = try await appState.marmot.sendText(
                accountRef: accountRef,
                groupIdHex: groupId,
                text: DiagnosticSelfSend.pingText(now: Date())
            )
            append("sent ping to self in \(IdentityFormatter.short(groupId))")
        } catch {
            append("send-to-self failed: \(error.localizedDescription)")
        }
    }

    private func diagnosticGroupId(accountRef: String) async throws -> String {
        let rows = try await appState.currentMarmotClient().chatList(
            accountRef: accountRef,
            includeArchived: true
        )
        if let row = DiagnosticSelfSend.reusableGroup(
            accountRef: accountRef,
            rows: rows
        ) {
            try await archiveDiagnosticGroupIfNeeded(row, accountRef: accountRef)
            return row.groupIdHex
        }

        let groupId = try await appState.marmot.createGroup(
            accountRef: accountRef,
            name: DiagnosticSelfSend.groupName,
            memberRefs: [],
            description: nil
        )
        DiagnosticSelfSend.remember(groupIdHex: groupId, accountRef: accountRef)
        _ = try await appState.marmot.setGroupArchived(
            accountRef: accountRef,
            groupIdHex: groupId,
            archived: true
        )
        return groupId
    }

    private func archiveDiagnosticGroupIfNeeded(_ row: ChatListRowFfi, accountRef: String) async throws {
        guard !row.archived else { return }
        _ = try await appState.marmot.setGroupArchived(
            accountRef: accountRef,
            groupIdHex: row.groupIdHex,
            archived: true
        )
    }
}

enum DiagnosticSelfSend {
    static let groupName = "Self check"

    private static let defaultsKeyPrefix = "marmot.diagnostics.selfGroupId."

    static func reusableGroup(
        accountRef: String,
        rows: [ChatListRowFfi],
        defaults: UserDefaults = .standard
    ) -> ChatListRowFfi? {
        guard let storedGroupId = storedGroupId(accountRef: accountRef, defaults: defaults) else {
            return nil
        }
        return rows.first { $0.groupIdHex == storedGroupId }
    }

    static func remember(
        groupIdHex: String,
        accountRef: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(groupIdHex, forKey: defaultsKey(accountRef: accountRef))
    }

    static func pingText(now: Date) -> String {
        "ping at \(now.formatted(date: .omitted, time: .standard))"
    }

    private static func storedGroupId(
        accountRef: String,
        defaults: UserDefaults
    ) -> String? {
        defaults.string(forKey: defaultsKey(accountRef: accountRef))
    }

    private static func defaultsKey(accountRef: String) -> String {
        defaultsKeyPrefix + accountRef
    }
}

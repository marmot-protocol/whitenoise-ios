import SwiftUI
import MarmotKit

/// Developer-facing scratchpad. Lives behind the "Show diagnostics" toggle
/// in Settings. Streams the top-level event firehose into a scrollable log.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var appState
    @State private var entries: [LogEntry] = []
    @State private var streaming = false

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
        .task {
            streaming = true
            defer { streaming = false }
            let sub = appState.marmot.subscribeEvents()
            for await event in SubscriptionDriver.events(sub) {
                append(describe(event))
            }
        }
    }

    private func append(_ text: String) {
        entries.append(LogEntry(timestamp: Date(), text: text))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    private func describe(_ event: MarmotEventFfi) -> String {
        switch event {
        case .groupJoined(_, let label, let groupIdHex):
            return "[\(label)] joined group \(IdentityFormatter.short(groupIdHex))"
        case .groupStateUpdated(_, let label, let groupIdHex):
            return "[\(label)] group state ↺ \(IdentityFormatter.short(groupIdHex))"
        case .messageReceived(let received):
            return "[\(received.accountLabel)] msg from \(IdentityFormatter.short(received.message.sender)): \(received.message.plaintext)"
        case .projectionUpdated(let update):
            return "[\(update.accountLabel)] projection \(IdentityFormatter.short(update.update.groupIdHex))"
        case .groupEvent(_, let label):
            return "[\(label)] group event"
        case .accountError(_, let label, let message):
            return "[\(label)] error: \(message)"
        case .agentStreamActivity(_, let label):
            return "[\(label)] agent stream activity"
        }
    }

    @MainActor
    private func sendToSelf() async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            let groupId = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: "diagnostic-\(Int(Date().timeIntervalSince1970))",
                memberRefs: [],
                description: nil
            )
            _ = try await appState.marmot.sendText(
                accountRef: accountRef,
                groupIdHex: groupId,
                text: "ping at \(Date().formatted(date: .omitted, time: .standard))"
            )
            append("sent ping to self in \(IdentityFormatter.short(groupId))")
        } catch {
            append("send-to-self failed: \(error.localizedDescription)")
        }
    }
}

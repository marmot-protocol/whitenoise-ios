import SwiftUI
import MarmotKit

/// Shared report details, distinct from the message's sender and sent time.
struct ReportDetailsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let report: ContentReportFfi
    let reporterName: String

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerLayout {
                Label(ReportPresentation.title(report.reason), systemImage: "exclamationmark.bubble")
                    .font(.headline)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(Date(timeIntervalSince1970: TimeInterval(report.reportedAt)), format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(L10n.formatted("Reported by %@", reporterName))
                .font(.subheadline).foregroundStyle(.secondary)
            if !report.explanation.isEmpty {
                Text(String(report.explanation.prefix(1000)))
                    .font(.body).textSelection(.enabled)
            }
            if report.dismissed {
                Label("Dismissed", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .labelStyle(ReportLabelStyle())
    }
}

private struct ReportLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

nonisolated protocol MessageReportsClient: Sendable {
    func messageReports(accountRef: String, groupID: String, messageID: String, after: String?) async throws -> ContentReportPageFfi
}

extension MarmotClient: MessageReportsClient {}

@MainActor @Observable
final class MessageReportsModel {
    private(set) var reports: [ContentReportFfi] = []
    private(set) var nextCursor: String?
    private(set) var loading = false
    private(set) var error: String?
    private var requestID = UUID()
    @ObservationIgnored private let clientOverride: (any MessageReportsClient)?

    init(client: (any MessageReportsClient)? = nil) { clientOverride = client }

    func load(messageID: String, conversation: ConversationViewModel, appState: AppState, more: Bool = false) async {
        guard conversation.canReadReports, let account = appState.activeAccountRef else {
            requestID = UUID()
            reports = []
            nextCursor = nil
            loading = false
            return
        }
        guard !more || (!loading && nextCursor != nil) else { return }
        let request = UUID()
        requestID = request
        let generation = appState.runtimeGeneration
        loading = true
        error = nil
        defer { if requestID == request { loading = false } }
        do {
            let client: any MessageReportsClient
            if let clientOverride { client = clientOverride }
            else { client = try appState.currentMarmotClient() }
            let page = try await client.messageReports(accountRef: account, groupID: conversation.group.groupIdHex,
                                                       messageID: messageID, after: more ? nextCursor : nil)
            try Task.checkCancellation()
            guard requestID == request, appState.activeAccountRef == account,
                  appState.runtimeGeneration == generation, conversation.canReadReports else { return }
            let existing = more ? reports : []
            let ids = Set(existing.map(\.reportIdHex))
            reports = existing + page.reports.filter { $0.messageIdHex == messageID && !ids.contains($0.reportIdHex) }
            nextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            guard requestID == request, appState.activeAccountRef == account,
                  appState.runtimeGeneration == generation else { return }
            self.error = UserFacingError.message(for: error)
        }
    }
}

struct MessageReportsSection: View {
    @Environment(AppState.self) private var appState
    let messageID: String
    let conversation: ConversationViewModel
    @State private var model = MessageReportsModel()
    @State private var revision = UUID()
    @State private var route: AppState.GroupRecoveryUpdate?
    @State private var operation: Task<Void, Never>?

    private var refreshKey: String {
        "\(messageID):\(revision):\(appState.activeAccountRef ?? ""):\(appState.runtimeGeneration):\(appState.canUseRuntimeForForegroundWork)"
    }

    var body: some View {
        Section("Reports") {
            if conversation.canReadReports {
                ForEach(model.reports, id: \.reportIdHex) { report in
                    ReportDetailsView(report: report, reporterName: conversation.windowDisplayName(for: report.reporter))
                        .padding(.vertical, 6)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { load() }
                } else if model.reports.isEmpty, !model.loading {
                    Text("No reports").foregroundStyle(.secondary)
                }
                if model.loading { ProgressView() }
                if model.nextCursor != nil {
                    Button("Load more") { load(more: true) }.disabled(model.loading)
                }
            }
        }
        .onAppear {
            guard let account = appState.activeAccount?.accountIdHex else { return }
            let route = AppState.GroupRecoveryUpdate(accountID: account, groupID: conversation.group.groupIdHex)
            self.route = route
            appState.moderationProjectionRoute = route
        }
        .onChange(of: appState.groupProjectionUpdate) { _, update in
            guard let update, update.groupID == conversation.group.groupIdHex,
                  update.accountID == appState.activeAccount?.accountIdHex else { return }
            revision = update.id
        }
        .task(id: refreshKey) {
            await model.load(messageID: messageID, conversation: conversation, appState: appState)
        }
        .onDisappear {
            operation?.cancel()
            if appState.moderationProjectionRoute?.id == route?.id { appState.moderationProjectionRoute = nil }
        }
    }

    private func load(more: Bool = false) {
        operation?.cancel()
        operation = Task { await model.load(messageID: messageID, conversation: conversation, appState: appState, more: more) }
    }
}

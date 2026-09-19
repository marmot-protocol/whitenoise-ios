import SwiftUI
import MarmotKit

nonisolated enum ReportPresentation {
    static let reasons: [ReportReasonFfi] = [.spam, .nudity, .malware, .profanity, .illegal, .impersonation, .other]

    static func title(_ reason: ReportReasonFfi) -> String {
        switch reason {
        case .spam: L10n.string("Spam")
        case .nudity: L10n.string("Nudity")
        case .malware: L10n.string("Malware")
        case .profanity: L10n.string("Profanity")
        case .illegal: L10n.string("Illegal content")
        case .impersonation: L10n.string("Impersonation")
        case .other: L10n.string("Other")
        }
    }

    static func outcome(_ summary: SendSummaryFfi) -> String {
        switch summary.acceptDisposition {
        case .published: L10n.string("Sent to the group.")
        case .acceptedPending: L10n.string("Saved and waiting to send.")
        case .completionUnknown: L10n.string("Saved; delivery confirmation is pending.")
        }
    }
}

struct ReportMessageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let conversation: ConversationViewModel
    let message: AppMessageRecordFfi
    @State private var reason: ReportReasonFfi = .spam
    @State private var explanation = ""
    @State private var sending = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportPresentation.reasons, id: \.self) { reason in
                            Text(ReportPresentation.title(reason)).tag(reason)
                        }
                    }
                    TextField("Explanation (optional)", text: $explanation, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: explanation) { _, value in explanation = String(value.prefix(1000)) }
                } footer: {
                    Text("Reports are shared inside this encrypted group. Group members can read your report and explanation.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Report Message") { operation = Task { await submit() } }
                        .disabled(sending || !conversation.canReport(message))
                    if sending { ProgressView() }
                }
            }
            .navigationTitle("Report Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) } }
        }
        .interactiveDismissDisabled(sending)
        .onDisappear { operation?.cancel() }
    }

    private func submit() async {
        guard !sending, conversation.canReport(message), let account = appState.activeAccountRef else { return }
        let generation = appState.runtimeGeneration
        sending = true
        error = nil
        defer { sending = false }
        do {
            let client = try appState.currentMarmotClient()
            let result = try await client.reportMessage(accountRef: account, groupID: conversation.group.groupIdHex,
                messageID: message.messageIdHex, reason: reason, explanation: explanation)
            try Task.checkCancellation()
            guard appState.activeAccountRef == account, appState.runtimeGeneration == generation else { return }
            appState.present(.success(L10n.string("Report submitted"), message: ReportPresentation.outcome(result)))
            dismiss()
        } catch is CancellationError {
        } catch {
            guard appState.activeAccountRef == account, appState.runtimeGeneration == generation else { return }
            self.error = UserFacingError.message(for: error)
        }
    }
}

nonisolated protocol GroupModerationClient: Sendable {
    func contentReports(accountRef: String, groupID: String, after: String?) async throws -> ContentReportPageFfi
    func reportedMessage(accountRef: String, groupID: String, messageID: String) async throws -> TimelineMessageRecordFfi?
    func dismissReport(accountRef: String, groupID: String, reportID: String) async throws -> SendSummaryFfi
    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi
}

extension MarmotClient: GroupModerationClient {}

@MainActor
@Observable
final class GroupModerationModel {
    struct Entry: Identifiable {
        var id: String { report.reportIdHex }
        let report: ContentReportFfi
        let message: TimelineMessageRecordFfi?
        var markdownBlocks: [MarkdownDisplayBlock]?
        var mediaItems: [MessageMediaAttachment] = []
    }
    private(set) var entries: [Entry] = []
    private(set) var nextCursor: String?
    private(set) var loading = false
    private(set) var acting = false
    private(set) var pendingActions: [String: Bool] = [:]
    var error: String?
    var status: String?
    private var requestID = UUID()
    @ObservationIgnored private let clientOverride: (any GroupModerationClient)?

    init(client: (any GroupModerationClient)? = nil) { clientOverride = client }

    private func client(using appState: AppState) throws -> any GroupModerationClient {
        if let clientOverride { return clientOverride }
        return try appState.currentMarmotClient()
    }

    func load(conversation: ConversationViewModel, appState: AppState, more: Bool = false) async {
        guard !acting else { return }
        guard conversation.canModerateReports, let account = appState.activeAccountRef else {
            entries = []
            return
        }
        if more && (loading || nextCursor == nil) { return }
        let request = UUID()
        requestID = request
        let generation = appState.runtimeGeneration
        loading = true
        error = nil
        defer { if requestID == request { loading = false } }
        do {
            let client = try client(using: appState)
            let page = try await client.contentReports(accountRef: account, groupID: conversation.group.groupIdHex,
                                                       after: more ? nextCursor : nil)
            var rows: [Entry] = []
            for report in page.reports where !report.dismissed {
                try Task.checkCancellation()
                let message = try await client.reportedMessage(accountRef: account,
                    groupID: conversation.group.groupIdHex, messageID: report.messageIdHex)
                var entry = Entry(report: report, message: message)
                if let message, !message.deleted {
                    entry.markdownBlocks = MarkdownMessageBuilder.displayBlocks(
                        for: message.contentTokens)
                    // Review projections can include personally blocked targets absent from the normal window.
                    entry.mediaItems = MessageMediaAttachment.displayItems(fromOutcomes: message.media,
                        ownerId: "report:\(report.reportIdHex):\(message.messageIdHex)")
                }
                rows.append(entry)
            }
            try Task.checkCancellation()
            guard requestID == request, appState.activeAccountRef == account,
                  appState.runtimeGeneration == generation, conversation.canModerateReports else { return }
            for report in page.reports where report.dismissed { pendingActions[report.reportIdHex] = nil }
            for row in rows where row.message?.deleted == true { pendingActions[row.id] = nil }
            let existing = more ? entries : []
            let ids = Set(existing.map(\.id))
            entries = existing + rows.filter { !ids.contains($0.id) }
            nextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            guard requestID == request, appState.activeAccountRef == account,
                  appState.runtimeGeneration == generation else { return }
            self.error = UserFacingError.message(for: error)
        }
    }

    func act(on entry: Entry, deleting: Bool, conversation: ConversationViewModel, appState: AppState) async {
        guard !acting, pendingActions[entry.id] == nil, conversation.canModerateReports, let account = appState.activeAccountRef else { return }
        let generation = appState.runtimeGeneration
        requestID = UUID()
        loading = false
        acting = true
        error = nil
        do {
            let client = try client(using: appState)
            let result: SendSummaryFfi
            if deleting {
                result = try await client.deleteMessage(accountRef: account, groupIdHex: conversation.group.groupIdHex,
                                                       targetMessageId: entry.report.messageIdHex)
            } else {
                result = try await client.dismissReport(accountRef: account, groupID: conversation.group.groupIdHex,
                                                       reportID: entry.id)
            }
            try Task.checkCancellation()
            guard appState.activeAccountRef == account, appState.runtimeGeneration == generation else {
                acting = false
                return
            }
            status = ReportPresentation.outcome(result)
            if result.acceptDisposition != .published { pendingActions[entry.id] = deleting }
        } catch is CancellationError {
        } catch {
            if appState.activeAccountRef == account, appState.runtimeGeneration == generation {
                self.error = UserFacingError.message(for: error)
            }
        }
        acting = false
        // Reload authoritative dismissals and deletion-masked message content.
        if error == nil { await load(conversation: conversation, appState: appState) }
    }
}

struct GroupModerationView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppState.self) private var appState
    let conversation: ConversationViewModel
    @State private var model = GroupModerationModel()
    @State private var projectionRevision = UUID()
    @State private var projectionRoute: AppState.GroupRecoveryUpdate?
    @State private var deleteTarget: GroupModerationModel.Entry?
    @State private var operation: Task<Void, Never>?

    init(conversation: ConversationViewModel, model: GroupModerationModel? = nil) {
        self.conversation = conversation
        _model = State(initialValue: model ?? GroupModerationModel())
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var refreshKey: String {
        "\(projectionRevision.uuidString):\(appState.activeAccountRef ?? ""):\(appState.runtimeGeneration):\(conversation.canModerateReports)"
    }

    var body: some View {
        List {
            if !conversation.canModerateReports {
                Text("Only active group admins can review reports.")
            } else {
                if let status = model.status { Section { Text(status).foregroundStyle(.secondary) } }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Retry") { reload() }
                    }
                }
                if model.entries.isEmpty, !model.loading, model.nextCursor == nil, model.error == nil {
                    Text("No reports to review.")
                }
                ForEach(model.entries) { entry in
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            ReportDetailsView(report: entry.report, reporterName: conversation.windowDisplayName(for: entry.report.reporter))
                            Divider()
                            if let message = entry.message {
                                MessageBubble(
                                    record: ConversationViewModel.appMessageRecord(from: message),
                                    status: message.direction == "sent" ? .sent : .received,
                                    isDeleted: message.deleted,
                                    deletionSource: message.deletionSource,
                                    isEdited: message.edit != nil,
                                    hasReports: message.hasReports,
                                    usesReviewLayout: true,
                                    clusterPresentation: .init(reservesIdentityLane: true, showsSenderName: true, showsAvatar: true),
                                    mediaItems: entry.mediaItems,
                                    markdownBlocks: entry.markdownBlocks,
                                    identityName: conversation.windowDisplayName,
                                    identityAvatarAsset: { conversation.windowIdentities[$0]?.avatarAsset },
                                    onLoadMedia: ConversationMediaLoader { try await conversation.data(for: $0) }
                                )
                                Text(Date(timeIntervalSince1970: TimeInterval(message.timelineAt)), format: .dateTime.day().month().year())
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Message unavailable").foregroundStyle(.secondary)
                            }
                            if model.pendingActions[entry.id] != nil {
                                Text("Saved; delivery confirmation is pending.").font(.caption).foregroundStyle(.secondary)
                            }
                            actionLayout {
                                WNButton(title: "Dismiss", systemImage: "checkmark", emphasis: .secondary, size: .standard) {
                                    act(entry, deleting: false)
                                }
                                WNButton(title: "Delete", systemImage: "trash", emphasis: .destructive, size: .standard) {
                                    deleteTarget = entry
                                }
                                .disabled(entry.message == nil || entry.message?.deleted == true)
                            }
                        }
                        .padding(.vertical, 8)

                    }
                    .disabled(model.acting || model.pendingActions[entry.id] != nil)
                }
                if model.loading || model.acting { ProgressView() }
                if model.nextCursor != nil {
                    Button("Load more") {
                        operation = Task { await model.load(conversation: conversation, appState: appState, more: true) }
                    }.disabled(model.loading || model.acting)
                }
            }
        }
        .navigationTitle("Moderation")
        .onAppear {
            guard let accountID = appState.activeAccount?.accountIdHex else { return }
            let route = AppState.GroupRecoveryUpdate(accountID: accountID, groupID: conversation.group.groupIdHex)
            projectionRoute = route
            appState.moderationProjectionRoute = route
        }
        .onChange(of: appState.groupProjectionUpdate) { _, update in
            guard let update, update.groupID == conversation.group.groupIdHex,
                  update.accountID == appState.activeAccount?.accountIdHex else { return }
            projectionRevision = update.id
        }
        .task(id: refreshKey) { await model.load(conversation: conversation, appState: appState) }
        .refreshable { await model.load(conversation: conversation, appState: appState) }
        .confirmationDialog("Delete message?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
        ), titleVisibility: .visible, presenting: deleteTarget) { entry in
            Button("Delete Message", role: .destructive) { act(entry, deleting: true) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the message for members using compatible clients. Older clients may retain it. Dismissing a report does not delete the message.")
        }
        .onDisappear {
            operation?.cancel()
            if appState.moderationProjectionRoute?.id == projectionRoute?.id {
                appState.moderationProjectionRoute = nil
            }
        }
    }

    private func reload() {
        operation = Task { await model.load(conversation: conversation, appState: appState) }
    }

    private func act(_ entry: GroupModerationModel.Entry, deleting: Bool) {
        deleteTarget = nil
        operation = Task { await model.act(on: entry, deleting: deleting, conversation: conversation, appState: appState) }
    }
}

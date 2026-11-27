import SwiftUI
import MarmotKit

/// Easy-to-reach Stop bar and waiting-subagent jump bar displayed right above
/// the composer while agent turns are running or a subagent needs attention.
struct AgentRunningControlBar: View {
    let runningTurns: [AgentItemProjection]
    let waitingSubagents: [(task: AgentItemProjection, waiting: AgentItemProjection)]
    let showsAgentName: Bool
    let agentDisplayName: (String) -> String
    let isStopPending: (AgentItemProjection) -> Bool
    let onStop: (AgentItemProjection) -> Void
    let onOpenSubagentThread: (AgentItemProjection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(waitingSubagents, id: \.task.messageIdHex) { entry in
                waitingSubagentRow(task: entry.task, waiting: entry.waiting)
            }
            ForEach(runningTurns, id: \.messageIdHex) { turn in
                runningTurnRow(turn)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func waitingSubagentRow(task: AgentItemProjection, waiting: AgentItemProjection) -> some View {
        let subtitle: String? = {
            if case .task(let body) = task.body, let desc = body.description, !desc.isEmpty {
                return desc
            }
            return ContentSanitizer.compactSingleLine(task.plaintext, maxLength: 120) ?? task.sanitizedTitle
        }()
        return Button {
            onOpenSubagentThread(task)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(waiting.sanitizedTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(L10n.string("Review"))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func runningTurnRow(_ turn: AgentItemProjection) -> some View {
        let pending = isStopPending(turn)
        return HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                if showsAgentName {
                    Text(agentDisplayName(turn.sender))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(turn.sanitizedTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                onStop(turn)
            } label: {
                HStack(spacing: 5) {
                    if pending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                    }
                    Text(pending ? L10n.string("Stopping…") : L10n.string("Stop"))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Color.red, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(pending)
            .accessibilityLabel(L10n.string("Stop"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

/// Sheet presenting an agent's latest `session` item: New Session, Settings,
/// Harness Actions, and Slash Commands.
struct AgentSessionControlsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: ConversationViewModel
    let initialAgentPubkeyHex: String?
    let onInsertSlashCommand: (String) -> Void

    @State private var selectedAgentPubkeyHex: String?
    @State private var editingSetting: (agent: String, setting: AgentItemBody.SessionSetting)?
    @State private var customSettingValue = ""

    private var sessions: [AgentItemProjection] {
        viewModel.latestAgentSessions
    }

    private var sessionSelection: AgentSessionSelection {
        AgentSessionSelection.resolve(
            sessions: sessions,
            selectedAgentPubkeyHex: selectedAgentPubkeyHex,
            initialAgentPubkeyHex: initialAgentPubkeyHex
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch sessionSelection {
                case .selected(let projection):
                    if case .session(let session) = projection.body {
                        sessionForm(projection: projection, session: session)
                    } else {
                        noActiveSessionView
                    }
                case .unavailable(let target, let alternatives):
                    unavailableSessionView(targetPubkeyHex: target, alternatives: alternatives)
                case .empty:
                    noActiveSessionView
                }
            }
            .navigationTitle(L10n.string("Agent Controls"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { dismiss() }
                }
            }
            .alert(
                editingSetting?.setting.label ?? L10n.string("Update setting"),
                isPresented: Binding(
                    get: { editingSetting != nil },
                    set: { if !$0 { editingSetting = nil } }
                )
            ) {
                TextField(L10n.string("Value"), text: $customSettingValue)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L10n.string("Save")) {
                    if let target = editingSetting {
                        let trimmed = customSettingValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Task {
                                await viewModel.sendAgentSetSetting(
                                    agentPubkeyHex: target.agent,
                                    setting: target.setting,
                                    value: trimmed
                                )
                            }
                        }
                    }
                    editingSetting = nil
                }
                Button(L10n.string("Cancel"), role: .cancel) {
                    editingSetting = nil
                }
            }
        }
    }

    private var noActiveSessionView: some View {
        ContentUnavailableView(
            L10n.string("No active agent session"),
            systemImage: "cpu",
            description: Text(L10n.string("Agent settings and actions will appear here once an agent starts a session."))
        )
    }

    private func unavailableSessionView(
        targetPubkeyHex: String,
        alternatives: [AgentItemProjection]
    ) -> some View {
        Form {
            Section {
                ContentUnavailableView(
                    L10n.string("No active agent session"),
                    systemImage: "cpu",
                    description: Text(viewModel.windowDisplayName(for: targetPubkeyHex))
                )
            }
            if !alternatives.isEmpty {
                Section(L10n.string("Agent")) {
                    ForEach(alternatives, id: \.sender) { item in
                        Button {
                            selectedAgentPubkeyHex = item.sender
                        } label: {
                            HStack {
                                Text(viewModel.windowDisplayName(for: item.sender))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionForm(projection: AgentItemProjection, session: AgentItemBody.Session) -> some View {
        let agent = projection.sender
        let newSessionPending = viewModel.agentInteractions.isPending(
            key: AgentInteractionStore.newSessionKey(agentPubkeyHex: agent)
        )
        return Form {
            if sessions.count > 1 {
                Section(L10n.string("Agent")) {
                    Picker(
                        L10n.string("Agent"),
                        selection: Binding(
                            get: { agent },
                            set: { selectedAgentPubkeyHex = $0 }
                        )
                    ) {
                        ForEach(sessions, id: \.sender) { item in
                            Text(viewModel.windowDisplayName(for: item.sender)).tag(item.sender)
                        }
                    }
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.windowDisplayName(for: agent))
                            .font(.headline)
                        Text([projection.item.harness, session.harnessVersion].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AgentItemStateBadge(state: projection.item.state)
                }

                Button {
                    Task { await viewModel.sendAgentNewSession(agentPubkeyHex: agent) }
                } label: {
                    HStack {
                        Label(L10n.string("New Session"), systemImage: "plus.bubble")
                        Spacer()
                        if newSessionPending {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(newSessionPending || !viewModel.canSendMessages)
            }

            if !session.settings.isEmpty {
                Section(L10n.string("Settings")) {
                    ForEach(session.settings) { setting in
                        let pending = viewModel.agentInteractions.isPending(
                            key: AgentInteractionStore.setSettingKey(agentPubkeyHex: agent, settingId: setting.id)
                        )
                        if let options = setting.options, !options.isEmpty {
                            Menu {
                                ForEach(options, id: \.self) { option in
                                    Button {
                                        Task {
                                            await viewModel.sendAgentSetSetting(
                                                agentPubkeyHex: agent,
                                                setting: setting,
                                                value: option
                                            )
                                        }
                                    } label: {
                                        if option == setting.value {
                                            Label(option, systemImage: "checkmark")
                                        } else {
                                            Text(option)
                                        }
                                    }
                                }
                            } label: {
                                settingRowLabel(setting: setting, pending: pending)
                            }
                            .disabled(pending || !viewModel.canSendMessages)
                        } else {
                            Button {
                                customSettingValue = setting.value ?? ""
                                editingSetting = (agent, setting)
                            } label: {
                                settingRowLabel(setting: setting, pending: pending)
                            }
                            .disabled(pending || !viewModel.canSendMessages)
                        }
                    }
                }
            }

            if !session.actions.isEmpty {
                Section(L10n.string("Actions")) {
                    ForEach(session.actions) { action in
                        let pending = viewModel.agentInteractions.isPending(
                            key: AgentInteractionStore.ownActionKey(agentPubkeyHex: agent, actionId: action.id)
                        )
                        Button {
                            Task { await viewModel.sendAgentOwnAction(agentPubkeyHex: agent, action: action) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.label)
                                        .foregroundStyle(.primary)
                                    if let desc = action.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if pending {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(pending || !viewModel.canSendMessages)
                    }
                }
            }

            if !session.commands.isEmpty {
                Section(L10n.string("Slash Commands")) {
                    ForEach(session.commands) { command in
                        Button {
                            let insertion = command.hint.isEmpty ? "/\(command.name)" : "/\(command.name) "
                            onInsertSlashCommand(insertion)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("/\(command.name)")
                                        .font(.subheadline.monospaced().weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if !command.hint.isEmpty {
                                        Text(command.hint)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let desc = command.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func settingRowLabel(setting: AgentItemBody.SessionSetting, pending: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(setting.label)
                        .foregroundStyle(.primary)
                    if setting.approve {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.string("Requires approval right"))
                    }
                }
            }
            Spacer(minLength: 8)
            if pending {
                ProgressView().controlSize(.small)
            } else {
                Text(setting.value?.isEmpty == false ? setting.value! : L10n.string("Default"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Thread sheet for a Codex subagent (`task` item of kind `subagent`), showing
/// its kind-1201 items, kind-1111 words, nested subagents, and a thread-scoped Stop.
struct AgentSubagentThreadView: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: ConversationViewModel
    let rootTaskMessageIdHex: String
    let onOpenSessionControls: (AgentItemProjection) -> Void
    let onInsertDraftText: (String) -> Void

    var body: some View {
        NavigationStack {
            AgentSubagentThreadContent(
                viewModel: viewModel,
                taskMessageIdHex: rootTaskMessageIdHex,
                onOpenSessionControls: onOpenSessionControls,
                onInsertDraftText: onInsertDraftText
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("Done")) { dismiss() }
                }
            }
        }
    }
}

private struct AgentSubagentThreadContent: View {
    let viewModel: ConversationViewModel
    let taskMessageIdHex: String
    let onOpenSessionControls: (AgentItemProjection) -> Void
    let onInsertDraftText: (String) -> Void

    @State private var nestedTaskId: String?

    private var taskProjection: AgentItemProjection? {
        viewModel.agentItemProjection(forMessageId: taskMessageIdHex)
    }

    private var threadItems: [TimelineItem] {
        viewModel.subagentThreadItems(forTaskMessageId: taskMessageIdHex)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let task = taskProjection {
                taskHeader(task)
                Divider()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if threadItems.isEmpty {
                        ContentUnavailableView(
                            L10n.string("No activity yet"),
                            systemImage: "person.2.wave.2",
                            description: Text(L10n.string("Subagent steps and messages will appear here as it works."))
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(threadItems) { item in
                            threadRow(for: item)
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.string("Subagents don't take direct messages. Write in the main chat."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle(taskProjection?.subagentTaskLabel ?? L10n.string("Subagent"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $nestedTaskId) { childId in
            AgentSubagentThreadContent(
                viewModel: viewModel,
                taskMessageIdHex: childId,
                onOpenSessionControls: onOpenSessionControls,
                onInsertDraftText: onInsertDraftText
            )
        }
    }

    private func taskHeader(_ task: AgentItemProjection) -> some View {
        let stopPending = viewModel.agentInteractions.isPending(
            key: AgentInteractionStore.stopKey(agentPubkeyHex: task.sender, targetEventIdHex: task.messageIdHex)
        )
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.subagentTaskLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(viewModel.windowDisplayName(for: task.sender))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            AgentItemStateBadge(state: task.item.state)
            if task.item.state == .running, viewModel.canSendMessages {
                Button {
                    Task {
                        await viewModel.sendAgentInterrupt(
                            agentPubkeyHex: task.sender,
                            targetEventIdHex: task.messageIdHex
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        if stopPending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill").font(.caption2)
                        }
                        Text(stopPending ? L10n.string("Stopping…") : L10n.string("Stop"))
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(stopPending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func threadRow(for item: TimelineItem) -> some View {
        if case .message(let record, _) = item.kind {
            if let projection = viewModel.agentItemProjection(forMessageId: record.messageIdHex) {
                AgentItemRow(
                    projection: projection,
                    senderName: viewModel.windowDisplayName(for: record.sender),
                    showsSenderName: false,
                    isTwoPersonChat: viewModel.isTwoPersonChat,
                    canInteract: viewModel.canSendMessages,
                    pendingRequest: viewModel.agentInteractions.pendingRequest(forItemEventId: projection.messageIdHex),
                    stopPending: viewModel.agentInteractions.isPending(
                        key: AgentInteractionStore.stopKey(
                            agentPubkeyHex: projection.sender,
                            targetEventIdHex: projection.messageIdHex
                        )
                    ),
                    answeredByName: viewModel.answeredByDisplayName(for: projection),
                    subagentSummary: projection.isSubagentTask
                        ? viewModel.subagentThreadSummary(forTaskMessageId: projection.messageIdHex)
                        : nil,
                    pendingForSubagentItem: { id in
                        viewModel.agentInteractions.pendingRequest(forItemEventId: id)
                    },
                    onApproveChoice: { choice, target in
                        Task { await viewModel.sendAgentApprovalChoice(choice, for: target) }
                    },
                    onAnswerQuestion: { answers, target, secret, summary in
                        Task {
                            await viewModel.sendAgentQuestionAnswers(
                                answers,
                                for: target,
                                containsSecret: secret,
                                summary: summary
                            )
                        }
                    },
                    onStop: { target in
                        Task {
                            await viewModel.sendAgentInterrupt(
                                agentPubkeyHex: target.sender,
                                targetEventIdHex: target.messageIdHex
                            )
                        }
                    },
                    onOpenSessionControls: onOpenSessionControls,
                    onOpenSubagentThread: { childTask in
                        nestedTaskId = childTask.messageIdHex
                    },
                    onInsertDraftText: onInsertDraftText
                )
            } else {
                // Subagent words (kind 1111 comment) or human reply in thread.
                let isCommentary = MessageSemantics.isAgentCommentary(tags: record.tags)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.windowDisplayName(for: record.sender))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(ContentSanitizer.messageBody(record.plaintext))
                        .font(isCommentary ? .subheadline : .body)
                        .foregroundStyle(isCommentary ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: 540, alignment: .leading)
                .background(
                    Color(.secondarySystemBackground).opacity(isCommentary ? 0.65 : 1),
                    in: .rect(cornerRadius: 14, style: .continuous)
                )
                .padding(.horizontal, 12)
            }
        }
    }
}

import SwiftUI
import MarmotKit

/// Renders a structured agent item (kind 1201 with `AgentItemFfi`) in the
/// main conversation timeline or inside a subagent thread.
struct AgentItemRow: View {
    let projection: AgentItemProjection
    let senderName: String
    let showsSenderName: Bool
    let isTwoPersonChat: Bool
    let canInteract: Bool
    let pendingRequest: AgentInteractionStore.PendingRequest?
    let stopPending: Bool
    let answeredByName: String?
    let subagentSummary: AgentSubagentThreadSummary?
    let pendingForSubagentItem: (String) -> AgentInteractionStore.PendingRequest?
    let onApproveChoice: (AgentItemBody.ApprovalChoice, AgentItemProjection) -> Void
    let onAnswerQuestion: ([AgentQuestionReplyPayload], AgentItemProjection, Bool, String) -> Void
    let onStop: (AgentItemProjection) -> Void
    let onOpenSessionControls: (AgentItemProjection) -> Void
    let onOpenSubagentThread: (AgentItemProjection) -> Void
    let onInsertDraftText: (String) -> Void
    var onRecheckPendingStatus: (String) -> Void = { _ in }
    var debugStyle: MessageDebugStyle? = nil

    @State private var isExpanded = false
    @State private var selectedOptionsByQuestion: [String: [String]] = [:]
    @State private var typedTextByQuestion: [String: String] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                headerRow
                bodyContent
                if !projection.cuts.isEmpty {
                    cutsFooter
                }
                if let debugStyle {
                    debugFooter(debugStyle)
                }
            }
            .padding(12)
            .frame(maxWidth: 540, alignment: .leading)
            .background(cardBackground, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Header

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsSenderName || projection.firstEventMissing {
                HStack(spacing: 6) {
                    if showsSenderName {
                        Text(senderName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if projection.firstEventMissing {
                        Text(L10n.string("Earlier activity"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }
            }

            HStack(alignment: .center, spacing: 6) {
                Image(systemName: headerIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(headerIconColor)
                    .accessibilityHidden(true)

                Text(projection.sanitizedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isErrorItem ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                AgentItemStateBadge(state: projection.item.state)
            }
        }
    }

    // MARK: - Per-type body

    @ViewBuilder
    private var bodyContent: some View {
        switch projection.body {
        case .turn(let turn):
            turnBody(turn)
        case .tool(let tool):
            toolBody(tool)
        case .reasoning:
            reasoningBody
        case .plan(let plan):
            planBody(plan)
        case .notice(let notice):
            noticeBody(notice)
        case .error(let err):
            errorBody(err)
        case .session(let session):
            sessionBody(session)
        case .approval(let approval):
            approvalBody(approval)
        case .question(let question):
            questionBody(question)
        case .task(let task):
            taskBody(task)
        case .message, .unknown:
            fallbackBody
        }
    }

    // MARK: - Turn

    private func turnBody(_ turn: AgentItemBody.Turn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let startedBy = turn.startedBy {
                    Text(startedByLabel(startedBy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let ms = turn.durationMs {
                    Text(AgentItemFormatting.durationString(milliseconds: ms))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let usage = turn.usage {
                    let parts = [
                        usage.inputTokens.map { "\(AgentItemFormatting.tokenCountString($0)) in" },
                        usage.outputTokens.map { "\(AgentItemFormatting.tokenCountString($0)) out" },
                    ].compactMap { $0 }
                    if !parts.isEmpty {
                        Text(parts.joined(separator: " · "))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if projection.item.state == .running, canInteract {
                    Button {
                        onStop(projection)
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
                        .background(Color.red.opacity(0.14), in: Capsule())
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(stopPending)
                }
            }
            if let text = sanitizedPlaintext {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tool

    private func toolBody(_ tool: AgentItemBody.Tool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = toolSummaryLine(tool) {
                Text(summary)
                    .font(tool.kind == .command ? .caption.monospaced() : .caption)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(toolKindLabel(tool.kind))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                if let exitCode = tool.exitCode {
                    Text("exit \(exitCode)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
                }
                if let ms = tool.durationMs {
                    Text(AgentItemFormatting.durationString(milliseconds: ms))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !tool.changes.isEmpty {
                    Text(L10n.plural("%lld files", Int64(tool.changes.count)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if toolHasExpandableDetails(tool) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? L10n.string("Hide") : toolExpandLabel(tool))
                                .font(.caption.weight(.medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isExpanded {
                toolExpandedDetails(tool)
            }
        }
    }

    private func toolExpandedDetails(_ tool: AgentItemBody.Tool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cwd = tool.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let error = tool.error, !error.isEmpty {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let output = tool.output, !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8, style: .continuous))
            }
            if !tool.changes.isEmpty {
                ForEach(tool.changes) { change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if let kind = change.change {
                                Text(kind.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(changeKindColor(kind))
                            }
                            Text(change.path)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        if !change.diff.isEmpty {
                            ScrollView(.horizontal, showsIndicators: true) {
                                DiffLinesView(diff: change.diff)
                            }
                            .padding(8)
                            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            if let input = tool.inputPrettyJson, !input.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(input)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - Reasoning

    private var reasoningBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = sanitizedFullPlaintext, !text.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? L10n.string("Hide thinking") : L10n.string("Show thinking"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Plan

    private func planBody(_ plan: AgentItemBody.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plan.entries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: planEntryIcon(entry.state))
                                .font(.caption)
                                .foregroundStyle(planEntryColor(entry.state))
                                .padding(.top, 2)
                            Text(entry.text)
                                .font(.caption)
                                .foregroundStyle(entry.state == "done" ? .secondary : .primary)
                                .strikethrough(entry.state == "done")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let planText = plan.text, !planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let isLong = planText.count > 220
                Text(planText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded || !isLong ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded ? L10n.string("Show less") : L10n.string("Show full plan"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            } else if plan.entries.isEmpty, let fallback = sanitizedFullPlaintext {
                Text(fallback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Notice

    private func noticeBody(_ notice: AgentItemBody.Notice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = sanitizedFullPlaintext, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(notice.kind == "refused" ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if notice.kind == "refused", let reason = notice.reason, !reason.isEmpty {
                Text(reason.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            } else if let ms = notice.durationMs {
                Text(AgentItemFormatting.durationString(milliseconds: ms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Error

    private func errorBody(_ err: AgentItemBody.ErrorBody) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let text = sanitizedFullPlaintext, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let request = err.request, !request.isEmpty {
                    Text(request)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let code = err.code {
                    Text("code \(code)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if err.willRetry == true {
                    Text(L10n.string("Will retry"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Session

    private func sessionBody(_ session: AgentItemBody.Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(projection.item.harness)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if !session.harnessVersion.isEmpty {
                    Text(session.harnessVersion)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if canInteract {
                    Button {
                        onOpenSessionControls(projection)
                    } label: {
                        Label(L10n.string("Controls"), systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            let summaryParts = session.settings.compactMap { setting -> String? in
                guard let value = setting.value, !value.isEmpty else { return nil }
                return "\(setting.label): \(value)"
            }
            if !summaryParts.isEmpty {
                Text(summaryParts.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Approval (Interactive)

    private func approvalBody(_ approval: AgentItemBody.Approval) -> some View {
        let settledChoiceLabel: String? = approval.answer?.choice.flatMap { id in
            approval.choices.first(where: { $0.id == id })?.label ?? id
        }
        let redundantSettledText = projection.item.state != .waiting
            && settledChoiceLabel.map { label in
                sanitizedFullPlaintext?.caseInsensitiveCompare("Answered: \(label)") == .orderedSame
            } == true
        return VStack(alignment: .leading, spacing: 8) {
            if let text = sanitizedFullPlaintext, !text.isEmpty, !redundantSettledText {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 8, style: .continuous))
            }

            if projection.item.state == .waiting {
                if let pending = pendingRequest, !pending.sendFailed {
                    pendingStatusRow(pending)
                } else if canInteract {
                    if pendingRequest?.sendFailed == true {
                        Text(L10n.string("Couldn't send answer. Try again."))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    VStack(spacing: 6) {
                        ForEach(approval.choices) { choice in
                            Button {
                                onApproveChoice(choice, projection)
                            } label: {
                                Text(choice.label)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        choice.isAllow
                                            ? Color.accentColor
                                            : (choice.isDeny ? Color.red.opacity(0.14) : Color(.tertiarySystemFill)),
                                        in: .rect(cornerRadius: 10, style: .continuous)
                                    )
                                    .foregroundStyle(
                                        choice.isAllow
                                            ? Color.white
                                            : (choice.isDeny ? Color.red : Color.primary)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                settledApprovalFooter(approval)
            }
        }
    }

    private func settledApprovalFooter(_ approval: AgentItemBody.Approval) -> some View {
        let chosenLabel: String? = approval.answer?.choice.flatMap { id in
            approval.choices.first(where: { $0.id == id })?.label ?? id
        }
        return HStack(spacing: 6) {
            Image(systemName: projection.item.state == .done ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(projection.item.state == .done ? Color.green : Color.orange)
            if let chosenLabel {
                if let who = answeredByName {
                    Text(L10n.formatted("%@ · by %@", chosenLabel, who))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(chosenLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else if let who = answeredByName {
                Text(L10n.formatted("Answered by %@", who))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Question (Interactive)

    private func questionBody(_ question: AgentItemBody.Question) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if projection.item.state == .waiting {
                if question.requiresTerminalForSecrets(isTwoPersonChat: isTwoPersonChat) {
                    ForEach(question.questions) { asked in
                        askedQuestionPrompt(asked)
                    }
                    Label(
                        L10n.string("Answer it at the terminal"),
                        systemImage: "lock.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
                } else if question.isAnsweredByMessage {
                    ForEach(question.questions) { asked in
                        VStack(alignment: .leading, spacing: 6) {
                            askedQuestionPrompt(asked)
                            if !asked.options.isEmpty {
                                ForEach(asked.options) { option in
                                    Button {
                                        onInsertDraftText(option.label)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.label)
                                                    .font(.subheadline.weight(.medium))
                                                if let desc = option.description, !desc.isEmpty {
                                                    Text(desc)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer(minLength: 4)
                                            Image(systemName: "arrow.uturn.left")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 40, alignment: .leading)
                                        .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Text(L10n.string("Reply with a chat message to answer."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let pending = pendingRequest, !pending.sendFailed {
                    ForEach(question.questions) { asked in
                        askedQuestionPrompt(asked)
                    }
                    pendingStatusRow(pending)
                } else if canInteract {
                    if pendingRequest?.sendFailed == true {
                        Text(L10n.string("Couldn't send answer. Try again."))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    let isSingleQuickPick = question.questions.count == 1
                        && !question.questions[0].multiple
                        && !question.questions[0].allowText
                        && !question.questions[0].options.isEmpty

                    ForEach(question.questions) { asked in
                        VStack(alignment: .leading, spacing: 6) {
                            askedQuestionPrompt(asked)
                            if !asked.options.isEmpty {
                                ForEach(asked.options) { option in
                                    let isSelected = selectedOptionsByQuestion[asked.id]?.contains(option.id) == true
                                    Button {
                                        if isSingleQuickPick {
                                            let reply = AgentQuestionReplyPayload(
                                                question: asked.id,
                                                options: [option.id],
                                                text: nil
                                            )
                                            onAnswerQuestion([reply], projection, asked.secret, option.label)
                                        } else {
                                            toggleQuestionOption(question: asked, optionId: option.id)
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            if !isSingleQuickPick {
                                                Image(systemName: optionSelectionIcon(multiple: asked.multiple, selected: isSelected))
                                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                            }
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.label)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)
                                                if let desc = option.description, !desc.isEmpty {
                                                    Text(desc)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer(minLength: 4)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 40, alignment: .leading)
                                        .background(
                                            isSelected ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemBackground),
                                            in: .rect(cornerRadius: 10, style: .continuous)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if asked.allowText || asked.options.isEmpty {
                                let binding = Binding<String>(
                                    get: { typedTextByQuestion[asked.id] ?? "" },
                                    set: { typedTextByQuestion[asked.id] = $0 }
                                )
                                Group {
                                    if asked.secret {
                                        SecureField(L10n.string("Type secret answer…"), text: binding)
                                    } else {
                                        TextField(L10n.string("Type your answer…"), text: binding)
                                    }
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }

                    if !isSingleQuickPick {
                        Button {
                            submitQuestionForm(question)
                        } label: {
                            Text(L10n.string("Send Answer"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(
                                    canSubmitQuestionForm(question) ? Color.accentColor : Color(.tertiarySystemFill),
                                    in: .rect(cornerRadius: 10, style: .continuous)
                                )
                                .foregroundStyle(canSubmitQuestionForm(question) ? Color.white : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmitQuestionForm(question))
                    }
                }
            } else {
                settledQuestionFooter(question)
            }
        }
    }

    private func askedQuestionPrompt(_ asked: AgentItemBody.AskedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header = asked.header, !header.isEmpty {
                Text(header)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if asked.secret {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(asked.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settledQuestionFooter(_ question: AgentItemBody.Question) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let answers = question.answer, !answers.isEmpty {
                ForEach(Array(answers.enumerated()), id: \.offset) { _, ans in
                    let asked = question.questions.first(where: { $0.id == ans.question })
                    if question.isAnswerSecret(ans) {
                        Text(L10n.string("Answered (secret)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let optionLabels = ans.options.map { optId in
                            asked?.options.first(where: { $0.id == optId })?.label ?? optId
                        }
                        let parts = optionLabels + [ans.text].compactMap { $0 }.filter { !$0.isEmpty }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: ", "))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let text = sanitizedPlaintext {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let who = answeredByName {
                Text(L10n.formatted("Answered by %@", who))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Task (Subagent Thread Row)

    private func taskBody(_ task: AgentItemBody.TaskBody) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let label = projection.subagentTaskLabel
            if label != projection.sanitizedTitle {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if task.kind == "subagent" {
                // Waiting approval/question inside the subagent's thread surfaces right here.
                if let waitingList = subagentSummary?.waitingInteractions, !waitingList.isEmpty {
                    ForEach(waitingList, id: \.messageIdHex) { waiting in
                        subagentWaitingBanner(waiting)
                    }
                }

                Button {
                    onOpenSubagentThread(projection)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.caption)
                        let count = subagentSummary?.totalEntryCount ?? 0
                        Text(count > 0
                             ? L10n.plural("Open thread (%lld items)", Int64(count))
                             : L10n.string("Open thread"))
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subagentWaitingBanner(_ waiting: AgentItemProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(waiting.sanitizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(L10n.string("Needs you"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let text = ContentSanitizer.compactSingleLine(waiting.plaintext, maxLength: 140), !text.isEmpty {
                Text(text)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if case .approval(let approval) = waiting.body {
                if let pending = pendingForSubagentItem(waiting.messageIdHex), !pending.sendFailed {
                    pendingStatusRow(pending)
                } else if canInteract {
                    HStack(spacing: 6) {
                        ForEach(approval.choices.prefix(2)) { choice in
                            Button {
                                onApproveChoice(choice, waiting)
                            } label: {
                                Text(choice.label)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        choice.isAllow ? Color.accentColor : Color.red.opacity(0.14),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(choice.isAllow ? Color.white : Color.red)
                            }
                            .buttonStyle(.plain)
                        }
                        if approval.choices.count > 2 {
                            Button(L10n.string("More…")) {
                                onOpenSubagentThread(projection)
                            }
                            .font(.caption.weight(.medium))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }

    // MARK: - Fallback

    @ViewBuilder
    private var fallbackBody: some View {
        if let text = sanitizedFullPlaintext, !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared subviews & helpers

    private func pendingStatusRow(_ pending: AgentInteractionStore.PendingRequest) -> some View {
        HStack(spacing: 8) {
            if !pending.statusUnknown {
                ProgressView().controlSize(.small)
            }
            Text(L10n.formatted("Pending: %@", pending.summary))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if pending.statusUnknown, canInteract {
                Spacer(minLength: 4)
                Button(L10n.string("Retry")) {
                    onRecheckPendingStatus(pending.key)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private var cutsFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(projection.cuts, id: \.self) { cut in
                Label(cut.displayLabel, systemImage: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func debugFooter(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(style.kindLabel) · v\(projection.item.version) · \(projection.item.itemType)")
                .font(.caption2.monospaced())
            if !style.tagsSummary.isEmpty {
                Text(style.tagsSummary)
                    .font(.caption2.monospaced())
            }
        }
        .foregroundStyle(style.category.accentColor.opacity(0.85))
        .padding(.top, 2)
    }

    private var sanitizedPlaintext: String? {
        ContentSanitizer.compactSingleLine(projection.plaintext, maxLength: 240)
    }

    private var sanitizedFullPlaintext: String? {
        let trimmed = projection.plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ContentSanitizer.messageBody(trimmed)
    }

    private var isErrorItem: Bool {
        if case .error = projection.body { return true }
        return projection.item.state == .failed
    }

    private var isWaitingActionItem: Bool {
        projection.isWaitingInteraction || (subagentSummary?.waitingInteractions.isEmpty == false)
    }

    private var cardBackground: Color {
        if case .error = projection.body {
            return Color.red.opacity(0.08)
        }
        if case .notice(let notice) = projection.body, notice.kind == "refused" {
            return Color.orange.opacity(0.08)
        }
        if isWaitingActionItem {
            return Color.orange.opacity(0.07)
        }
        return Color(.secondarySystemBackground)
    }

    private var cardBorderColor: Color {
        if case .error = projection.body {
            return Color.red.opacity(0.45)
        }
        if case .notice(let notice) = projection.body, notice.kind == "refused" {
            return Color.orange.opacity(0.4)
        }
        if isWaitingActionItem {
            return Color.orange.opacity(0.55)
        }
        return Color.primary.opacity(0.08)
    }

    private var cardBorderWidth: CGFloat {
        (isWaitingActionItem || isErrorItem) ? 1.25 : 0.75
    }

    private var headerIconName: String {
        switch projection.body {
        case .turn: return "bolt.circle"
        case .tool(let tool): return toolIconName(tool.kind)
        case .reasoning: return "brain"
        case .plan: return "checklist"
        case .notice(let notice): return noticeIconName(notice.kind)
        case .error: return "exclamationmark.octagon.fill"
        case .session: return "cpu"
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.circle.fill"
        case .task: return "person.2.wave.2.fill"
        case .message, .unknown: return "sparkles"
        }
    }

    private var headerIconColor: Color {
        switch projection.body {
        case .error: return .red
        case .approval, .question: return projection.item.state == .waiting ? .orange : .secondary
        case .notice(let n) where n.kind == "refused" || n.kind == "warning": return .orange
        case .task: return .accentColor
        default: return .secondary
        }
    }

    private func toolIconName(_ kind: AgentItemBody.ToolKind) -> String {
        switch kind {
        case .command: "terminal"
        case .edit: "pencil.and.outline"
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .mcp: "puzzlepiece.extension"
        case .subagent: "person.2.wave.2"
        case .other: "wrench.and.screwdriver"
        }
    }

    private func toolKindLabel(_ kind: AgentItemBody.ToolKind) -> String {
        switch kind {
        case .command: L10n.string("Command")
        case .edit: L10n.string("Edit")
        case .read: L10n.string("Read")
        case .search: L10n.string("Search")
        case .fetch: L10n.string("Fetch")
        case .mcp: "MCP"
        case .subagent: L10n.string("Subagent")
        case .other: L10n.string("Tool")
        }
    }

    private func noticeIconName(_ kind: String) -> String {
        switch kind {
        case "refused": "hand.raised.slash.fill"
        case "warning": "exclamationmark.triangle.fill"
        case "compaction": "arrow.triangle.merge"
        case "waiting": "hourglass"
        case "retry": "arrow.clockwise"
        case "model_changed": "cpu"
        case "command_output": "terminal"
        default: "info.circle"
        }
    }

    private func startedByLabel(_ startedBy: String) -> String {
        switch startedBy {
        case "user": L10n.string("Started by user")
        case "agent": L10n.string("Started by agent")
        case "control": L10n.string("Started by control")
        default: startedBy
        }
    }

    private func toolSummaryLine(_ tool: AgentItemBody.Tool) -> String? {
        if let command = tool.command, !command.isEmpty { return command }
        if !tool.changes.isEmpty {
            return tool.changes.map(\.path).joined(separator: ", ")
        }
        if let query = tool.query, !query.isEmpty { return query }
        if let path = tool.path, !path.isEmpty { return path }
        if let text = sanitizedPlaintext, !text.isEmpty { return text }
        if !tool.name.isEmpty { return tool.name }
        return nil
    }

    private func toolHasExpandableDetails(_ tool: AgentItemBody.Tool) -> Bool {
        (tool.output?.isEmpty == false)
            || !tool.changes.isEmpty
            || (tool.error?.isEmpty == false)
            || (tool.inputPrettyJson?.isEmpty == false)
            || (tool.cwd?.isEmpty == false)
    }

    private func toolExpandLabel(_ tool: AgentItemBody.Tool) -> String {
        if !tool.changes.isEmpty { return L10n.string("Show diff") }
        if tool.output?.isEmpty == false { return L10n.string("Show output") }
        return L10n.string("Details")
    }

    private func changeKindColor(_ kind: String) -> Color {
        switch kind {
        case "add": .green
        case "delete": .red
        default: .orange
        }
    }

    private func planEntryIcon(_ state: String) -> String {
        switch state {
        case "done": "checkmark.circle.fill"
        case "running": "clock.arrow.circlepath"
        default: "circle"
        }
    }

    private func planEntryColor(_ state: String) -> Color {
        switch state {
        case "done": .green
        case "running": .accentColor
        default: .secondary
        }
    }

    private func optionSelectionIcon(multiple: Bool, selected: Bool) -> String {
        if multiple {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func toggleQuestionOption(question: AgentItemBody.AskedQuestion, optionId: String) {
        var current = selectedOptionsByQuestion[question.id] ?? []
        if question.multiple {
            if let idx = current.firstIndex(of: optionId) {
                current.remove(at: idx)
            } else {
                current.append(optionId)
            }
        } else {
            current = current == [optionId] ? [] : [optionId]
        }
        selectedOptionsByQuestion[question.id] = current
    }

    private func canSubmitQuestionForm(_ question: AgentItemBody.Question) -> Bool {
        question.questions.contains { asked in
            let hasOption = !(selectedOptionsByQuestion[asked.id] ?? []).isEmpty
            let hasText = !(typedTextByQuestion[asked.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasOption || hasText
        }
    }

    private func submitQuestionForm(_ question: AgentItemBody.Question) {
        var replies: [AgentQuestionReplyPayload] = []
        var summaryParts: [String] = []
        let hasSecret = question.hasSecretQuestion
        for asked in question.questions {
            let options = selectedOptionsByQuestion[asked.id] ?? []
            let rawText = typedTextByQuestion[asked.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (rawText?.isEmpty == false) ? rawText : nil
            guard !options.isEmpty || text != nil else { continue }
            replies.append(AgentQuestionReplyPayload(question: asked.id, options: options, text: text))
            if !asked.secret {
                let labels = options.map { id in asked.options.first(where: { $0.id == id })?.label ?? id }
                summaryParts.append(contentsOf: labels)
                if let text { summaryParts.append(text) }
            }
        }
        guard !replies.isEmpty else { return }
        let summary = hasSecret ? L10n.string("Answer sent") : (summaryParts.isEmpty ? L10n.string("Answered") : summaryParts.joined(separator: ", "))
        onAnswerQuestion(replies, projection, hasSecret, summary)
    }
}

/// Compact pill showing an `AgentItemStateFfi`.
struct AgentItemStateBadge: View {
    let state: AgentItemStateFfi

    var body: some View {
        HStack(spacing: 4) {
            if state == .running {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(AgentItemFormatting.stateLabel(state))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(backgroundColor, in: Capsule())
    }

    private var foregroundColor: Color {
        switch state {
        case .running: .accentColor
        case .waiting: .orange
        case .done: .green
        case .failed: .red
        case .declined: .orange
        case .cancelled: .secondary
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.14)
    }
}

/// Renders unified diff lines with subtle red/green tinting.
private struct DiffLinesView: View {
    let diff: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                let line = String(rawLine)
                Text(line.isEmpty ? " " : line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(color(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(background(for: line))
            }
        }
        .textSelection(.enabled)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .red }
        if line.hasPrefix("@@") { return .accentColor }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.10) }
        return .clear
    }
}

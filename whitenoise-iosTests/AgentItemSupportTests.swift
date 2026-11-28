import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct AgentItemSupportTests {

    // MARK: - Item body parsing (all 11 types + fallback + cuts + privacy)

    @Test func parsesAllElevenItemTypesAndUnknownFallback() throws {
        // 1. turn
        let turn = AgentItemBody.parse(
            fieldsJson: #"{"type":"turn","body":{"started_by":"user","duration_ms":9341,"usage":{"input_tokens":31085,"output_tokens":71}}}"#,
            expectedType: "turn"
        )
        guard case .turn(let turnBody) = turn else {
            Issue.record("Expected .turn")
            return
        }
        #expect(turnBody.startedBy == "user")
        #expect(turnBody.durationMs == 9341)
        #expect(turnBody.usage?.inputTokens == 31085)
        #expect(turnBody.usage?.outputTokens == 71)

        // 2. tool (command + edit)
        let cmdTool = AgentItemBody.parse(
            fieldsJson: #"{"type":"tool","body":{"kind":"command","name":"shell","command":"python3 greet.py","cwd":"/work/demo","exit_code":0,"duration_ms":12,"output":"Hello, world\n"}}"#,
            expectedType: "tool"
        )
        guard case .tool(let cmd) = cmdTool else {
            Issue.record("Expected .tool")
            return
        }
        #expect(cmd.kind == .command)
        #expect(cmd.command == "python3 greet.py")
        #expect(cmd.exitCode == 0)
        #expect(cmd.output == "Hello, world\n")

        let editTool = AgentItemBody.parse(
            fieldsJson: #"{"type":"tool","body":{"kind":"edit","name":"apply_patch","changes":[{"path":"/work/demo/greet.py","change":"update","diff":"-old\n+new\n"}]}}"#,
            expectedType: "tool"
        )
        guard case .tool(let edit) = editTool else {
            Issue.record("Expected edit .tool")
            return
        }
        #expect(edit.kind == .edit)
        #expect(edit.changes.count == 1)
        #expect(edit.changes[0].path == "/work/demo/greet.py")
        #expect(edit.changes[0].change == "update")

        // 3. reasoning
        #expect(AgentItemBody.parse(fieldsJson: #"{"type":"reasoning","body":{}}"#, expectedType: "reasoning") == .reasoning)

        // 4. approval
        let approval = AgentItemBody.parse(
            fieldsJson: #"{"type":"approval","body":{"subject":"exec-1","choices":[{"id":"c0","label":"Allow once","effect":"allow"},{"id":"c1","label":"Deny","effect":"deny"}]}}"#,
            expectedType: "approval"
        )
        guard case .approval(let approvalBody) = approval else {
            Issue.record("Expected .approval")
            return
        }
        #expect(approvalBody.choices.count == 2)
        #expect(approvalBody.choices[0].isAllow)
        #expect(approvalBody.choices[1].isDeny)

        // 5. question
        let question = AgentItemBody.parse(
            fieldsJson: #"{"type":"question","body":{"answer_via":"request","questions":[{"id":"q0","header":"Greeting","text":"Which greeting?","multiple":false,"allow_text":true,"secret":true,"options":[{"id":"o0","label":"Hello","description":"Friendly"}]}]}}"#,
            expectedType: "question"
        )
        guard case .question(let questionBody) = question else {
            Issue.record("Expected .question")
            return
        }
        #expect(!questionBody.isAnsweredByMessage)
        #expect(questionBody.hasSecretQuestion)
        #expect(questionBody.questions.first?.options.first?.label == "Hello")

        // 6. plan
        let plan = AgentItemBody.parse(
            fieldsJson: #"{"type":"plan","body":{"entries":[{"text":"Write tests","state":"done"},{"text":"Ship build","state":"running"}]}}"#,
            expectedType: "plan"
        )
        guard case .plan(let planBody) = plan else {
            Issue.record("Expected .plan")
            return
        }
        #expect(planBody.entries.count == 2)
        #expect(planBody.entries[0].state == "done")

        // 7. task
        let task = AgentItemBody.parse(
            fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Update tests"}}"#,
            expectedType: "task"
        )
        guard case .task(let taskBody) = task else {
            Issue.record("Expected .task")
            return
        }
        #expect(taskBody.kind == "subagent")
        #expect(taskBody.description == "Update tests")

        // 8. notice (refused)
        let notice = AgentItemBody.parse(
            fieldsJson: #"{"type":"notice","body":{"kind":"refused","reason":"not_allowed"}}"#,
            expectedType: "notice"
        )
        guard case .notice(let noticeBody) = notice else {
            Issue.record("Expected .notice")
            return
        }
        #expect(noticeBody.kind == "refused")
        #expect(noticeBody.reason == "not_allowed")

        // 9. error
        let error = AgentItemBody.parse(
            fieldsJson: #"{"type":"error","body":{"request":"turn/start","code":-32600,"will_retry":true}}"#,
            expectedType: "error"
        )
        guard case .error(let errorBody) = error else {
            Issue.record("Expected .error")
            return
        }
        #expect(errorBody.code == -32600)
        #expect(errorBody.willRetry == true)

        // 10. session
        let session = AgentItemBody.parse(
            fieldsJson: #"{"type":"session","body":{"harness_version":"0.169.0","settings":[{"id":"model","label":"Model","value":"gpt-6.1-sol","options":["gpt-6.1-sol","o4"],"approve":false}],"actions":[{"id":"compact","label":"Compact"}],"commands":[{"name":"help","description":"Show help","hint":""}]}}"#,
            expectedType: "session"
        )
        guard case .session(let sessionBody) = session else {
            Issue.record("Expected .session")
            return
        }
        #expect(sessionBody.harnessVersion == "0.169.0")
        #expect(sessionBody.settings.first?.options?.count == 2)
        #expect(sessionBody.actions.first?.id == "compact")
        #expect(sessionBody.commands.first?.name == "help")

        // 11. message + unknown fallback
        #expect(AgentItemBody.parse(fieldsJson: #"{"type":"message","body":{"phase":"commentary"}}"#, expectedType: "message")
                == .message(.init(phase: "commentary", parent: nil)))
        #expect(AgentItemBody.parse(fieldsJson: #"{"type":"future_type","body":{"foo":1}}"#, expectedType: "future_type") == .unknown)
        #expect(AgentItemBody.parse(fieldsJson: "not json", expectedType: "tool") == .unknown)
    }

    @Test func parsesCutTagsAndRedactsDebugDescription() {
        let secret = "super-secret-command-arg"
        let item = makeAgentItem(
            itemType: "tool",
            state: .done,
            title: "Ran a command",
            fieldsJson: #"{"type":"tool","body":{"kind":"command","name":"shell","command":"\#(secret)"}}"#
        )
        let projection = AgentItemProjection.parse(
            messageIdHex: hex("01"),
            sender: hex("aa"),
            item: item,
            firstEventMissing: true,
            thread: nil,
            plaintext: secret,
            tags: [
                MessageTagFfi(values: ["cut", "output", "81920"]),
                MessageTagFfi(values: ["cut", "diffs", "3"]),
            ]
        )
        #expect(projection.firstEventMissing)
        #expect(projection.cuts.count == 2)
        #expect(projection.cuts[0].field == "output")
        #expect(projection.cuts[0].value == 81920)
        #expect(projection.cuts[1].field == "diffs")
        #expect(projection.cuts[1].value == 3)

        // Privacy (D-071): debugDescription never leaks plaintext, command, sender, or event id.
        let debug = projection.debugDescription
        #expect(!debug.contains(secret))
        #expect(!debug.contains(hex("01")))
        #expect(!debug.contains(hex("aa")))
    }

    // MARK: - Kind 1202 Request Builder & Secret Privacy Policy

    @Test func requestBuilderMatchesWireFormatForAllActions() throws {
        let agent = hex("aa")
        let target = hex("bb")

        // Approval choice
        let approval = AgentRequestBuilder.approvalChoice(
            agentPubkeyHex: agent,
            targetEventIdHex: target,
            choiceId: "c0",
            choiceLabel: "Allow once"
        )
        #expect(approval.kind == 1202)
        #expect(approval.content == "Allow once")
        #expect(approval.tags.contains(["p", agent]))
        #expect(approval.tags.contains(["e", target]))
        let approvalDetails = try decodeJSONObject(approval.tags.first(where: { $0.first == "details" })?[1])
        #expect(approvalDetails["action"] as? String == "choice")
        #expect(approvalDetails["choice"] as? String == "c0")

        // Secret question answer MUST NOT put secret text in content
        let secretReply = AgentRequestBuilder.questionAnswers(
            agentPubkeyHex: agent,
            targetEventIdHex: target,
            answers: [AgentQuestionReplyPayload(question: "pw", options: [], text: "hunter2")],
            containsSecret: true,
            nonSecretSummary: "hunter2"
        )
        #expect(secretReply.content == "Answered")
        #expect(!secretReply.content.contains("hunter2"))
        let qDetails = try decodeJSONObject(secretReply.tags.first(where: { $0.first == "details" })?[1])
        #expect(qDetails["action"] as? String == "questions")
        let qList = try #require(qDetails["questions"] as? [[String: Any]])
        #expect(qList.count == 1)
        #expect(qList[0]["question"] as? String == "pw")
        #expect(qList[0]["text"] as? String == "hunter2")

        // Interrupt with target turn
        let stop = AgentRequestBuilder.interrupt(agentPubkeyHex: agent, targetEventIdHex: target)
        #expect(stop.content == "Stop")
        #expect(stop.tags.contains(["e", target]))
        let stopDetails = try decodeJSONObject(stop.tags.first(where: { $0.first == "details" })?[1])
        #expect(stopDetails["action"] as? String == "interrupt")

        // New session (no e tag)
        let newSession = AgentRequestBuilder.newSession(agentPubkeyHex: agent)
        #expect(!newSession.tags.contains(where: { $0.first == "e" }))
        let nsDetails = try decodeJSONObject(newSession.tags.first(where: { $0.first == "details" })?[1])
        #expect(nsDetails["action"] as? String == "new_session")

        // Set setting
        let setModel = AgentRequestBuilder.setSetting(
            agentPubkeyHex: agent,
            settingId: "model",
            value: "gpt-6.1-sol",
            label: "Model"
        )
        #expect(setModel.content == "Model: gpt-6.1-sol")
        let setDetails = try decodeJSONObject(setModel.tags.first(where: { $0.first == "details" })?[1])
        #expect(setDetails["action"] as? String == "set")
        #expect(setDetails["setting"] as? String == "model")
        #expect(setDetails["value"] as? String == "gpt-6.1-sol")

        // Own action
        let compact = AgentRequestBuilder.ownAction(agentPubkeyHex: agent, actionId: "compact", label: "Compact")
        let ownDetails = try decodeJSONObject(compact.tags.first(where: { $0.first == "details" })?[1])
        #expect(ownDetails["action"] as? String == "own")
        #expect(ownDetails["id"] as? String == "compact")
    }

    @Test func secretQuestionsAreOnlyAllowedInTwoPersonChats() {
        #expect(!AgentQuestionPrivacyPolicy.canAnswerSecretQuestionInChat(memberCount: 0))
        #expect(!AgentQuestionPrivacyPolicy.canAnswerSecretQuestionInChat(memberCount: 1))
        #expect(AgentQuestionPrivacyPolicy.canAnswerSecretQuestionInChat(memberCount: 2))
        #expect(!AgentQuestionPrivacyPolicy.canAnswerSecretQuestionInChat(memberCount: 3))
    }

    @Test func commentaryTagIsDetectedOnAgentWords() {
        let commentaryTags = [
            MessageTagFfi(values: ["turn", "t1"]),
            MessageTagFfi(values: ["phase", "commentary"]),
        ]
        let finalTags = [
            MessageTagFfi(values: ["turn", "t1"]),
        ]
        #expect(MessageSemantics.isAgentCommentary(tags: commentaryTags))
        #expect(!MessageSemantics.isAgentCommentary(tags: finalTags))
    }

    // MARK: - Pending -> Settled lifecycle

    @MainActor
    @Test func pendingRequestClearsOnlyWhenEventIdAppearsInSettles() async throws {
        let store = AgentInteractionStore()
        let agent = hex("aa")
        let approvalId = hex("10")
        let requestId = hex("99")
        let me = hex("22")

        let payload = AgentRequestBuilder.approvalChoice(
            agentPubkeyHex: agent,
            targetEventIdHex: approvalId,
            choiceId: "c0",
            choiceLabel: "Allow once"
        )
        let key = AgentInteractionStore.itemKey(targetEventIdHex: approvalId)
        _ = try await store.submit(
            key: key,
            summary: "Allow once",
            senderAccountIdHex: me,
            payload: payload
        ) { _, token in
            LocalSendAcceptanceFfi(clientToken: token, messageIdHex: requestId)
        }

        // Still pending before any item settles it.
        #expect(store.isPending(key: key))
        store.reconcile(settledEventIds: [hex("88")])
        #expect(store.isPending(key: key))

        // Clears once the item lists `requestId` in `settles`.
        store.reconcile(settledEventIds: [requestId])
        #expect(!store.isPending(key: key))

        // Sender is known for the settled item.
        let settledItem = AgentItemProjection.parse(
            messageIdHex: approvalId,
            sender: agent,
            item: makeAgentItem(
                version: 2,
                itemType: "approval",
                state: .done,
                title: "Allow this command?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow once","effect":"allow"}],"answer":{"choice":"c0"}}}"#,
                settles: [requestId]
            ),
            firstEventMissing: false,
            thread: nil,
            plaintext: "Answered: Allow once",
            tags: []
        )
        #expect(store.settledByAccountId(for: settledItem) == me)
    }

    // MARK: - TimelineStore: in-place edits, old Hermes fallback, subagent threads, running turns

    @MainActor
    @Test func timelineUpdatesToolInPlaceAndKeepsPlainKind1201Visible() throws {
        let viewModel = ConversationViewModel(appState: AppState.test(), group: group(name: "Agent Chat", id: hex("bb")))
        let agent = hex("aa")
        let toolId = hex("01")
        let legacyHermesId = hex("02")

        let runningTool = timelineRecord(
            messageIdHex: toolId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "python3 greet.py",
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["v", "1"]), MessageTagFfi(values: ["state", "running"])],
            timelineAt: 10,
            agentItem: makeAgentItem(
                version: 1,
                itemType: "tool",
                state: .running,
                title: "Running a command",
                fieldsJson: #"{"type":"tool","body":{"kind":"command","name":"shell","command":"python3 greet.py"}}"#
            )
        )
        // Old Hermes kind 1201 with no `agent_item` and non-JSON plain text must still show.
        let legacyHermes = timelineRecord(
            messageIdHex: legacyHermesId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Hermes is searching files...",
            kind: MessageSemantics.kindAgentActivity,
            tags: [],
            timelineAt: 11,
            agentItem: nil
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [runningTool, legacyHermes], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 2)
        #expect(viewModel.agentItemProjection(forMessageId: toolId)?.item.state == .running)
        #expect(viewModel.agentItemProjection(forMessageId: legacyHermesId) == nil)
        #expect(AgentEventPresentation.plainFallbackDisplay(for: ConversationViewModel.appMessageRecord(from: legacyHermes)).primaryText == "Hermes is searching files...")

        // Tool transitions running -> done in place (same messageIdHex, version 2).
        let doneTool = timelineRecord(
            messageIdHex: toolId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "python3 greet.py",
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["v", "2"]), MessageTagFfi(values: ["state", "done"])],
            timelineAt: 10,
            agentItem: makeAgentItem(
                version: 2,
                itemType: "tool",
                state: .done,
                title: "Ran a command",
                fieldsJson: #"{"type":"tool","body":{"kind":"command","name":"shell","command":"python3 greet.py","exit_code":0,"output":"Hello\n"}}"#
            )
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [doneTool, legacyHermes], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.timeline.count == 2)
        let updated = try #require(viewModel.agentItemProjection(forMessageId: toolId))
        #expect(updated.item.version == 2)
        #expect(updated.item.state == .done)
    }

    @MainActor
    @Test func subagentThreadHidesChildItemsFromMainChatAndSurfacesWaitingApprovalOnTaskRow() throws {
        let viewModel = ConversationViewModel(appState: AppState.test(), group: group(name: "Codex", id: hex("bb")))
        let agent = hex("aa")
        let turnId = hex("10")
        let taskId = hex("20")
        let childToolId = hex("21")
        let childApprovalId = hex("22")
        let childWordsId = hex("23")

        let turnRecord = timelineRecord(
            messageIdHex: turnId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 1,
            agentItem: makeAgentItem(
                itemType: "turn",
                state: .running,
                title: "Working",
                fieldsJson: #"{"type":"turn","body":{"started_by":"user"}}"#
            )
        )
        let taskRecord = timelineRecord(
            messageIdHex: taskId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Update the tests",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 2,
            agentItem: makeAgentItem(
                itemId: "task:sub1",
                itemType: "task",
                state: .running,
                title: "Subagent",
                fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Update the tests"}}"#
            )
        )
        let threadRef = TimelineThreadRefFfi(rootMessageIdHex: taskId, parentMessageIdHex: taskId)
        let childTool = timelineRecord(
            messageIdHex: childToolId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "pytest",
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["subagent", "task:sub1"])],
            timelineAt: 3,
            thread: threadRef,
            agentItem: makeAgentItem(
                itemId: "tool:sub1",
                itemType: "tool",
                state: .running,
                title: "Running a command",
                fieldsJson: #"{"type":"tool","body":{"kind":"command","name":"shell","command":"pytest"}}"#
            )
        )
        let childApproval = timelineRecord(
            messageIdHex: childApprovalId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "pytest",
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["subagent", "task:sub1"])],
            timelineAt: 4,
            thread: threadRef,
            agentItem: makeAgentItem(
                itemId: "approval:sub1",
                itemType: "approval",
                state: .waiting,
                title: "Allow this command?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow once","effect":"allow"}]}}"#,
                alerts: true
            )
        )
        let childWords = timelineRecord(
            messageIdHex: childWordsId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "All tests pass.",
            kind: MessageSemantics.kindComment,
            tags: [
                MessageTagFfi(values: ["E", taskId, "", agent]),
                MessageTagFfi(values: ["K", "1201"]),
                MessageTagFfi(values: ["P", agent]),
                MessageTagFfi(values: ["e", taskId, "", agent]),
                MessageTagFfi(values: ["k", "1201"]),
            ],
            timelineAt: 5,
            thread: threadRef
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [turnRecord, taskRecord, childTool, childApproval, childWords],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )

        // Main timeline shows only the turn and the subagent task row — child items live in the thread.
        let mainIds = viewModel.timeline.compactMap { item -> String? in
            if case .message(let r, _) = item.kind { return r.messageIdHex }
            return nil
        }
        #expect(mainIds == [turnId, taskId])

        // Running turn is surfaced for the easy-to-reach Stop bar.
        #expect(viewModel.activeRunningAgentTurns.map(\.messageIdHex) == [turnId])

        // Subagent thread holds all 3 child rows and bubbles the waiting approval up to the task row.
        let summary = try #require(viewModel.subagentThreadSummary(forTaskMessageId: taskId))
        #expect(summary.totalEntryCount == 3)
        #expect(summary.directChildMessageIds == [childToolId, childApprovalId, childWordsId])
        #expect(summary.waitingInteractions.map(\.messageIdHex) == [childApprovalId])
        #expect(viewModel.subagentThreadItems(forTaskMessageId: taskId).count == 3)
        #expect(viewModel.waitingAgentSubagents.map(\.task.messageIdHex) == [taskId])
        #expect(viewModel.waitingAgentSubagents.map(\.waiting.messageIdHex) == [childApprovalId])
    }

    // MARK: - CodeRabbit regressions: secret questions, draft insertion, session target, ambiguous sends

    @Test func secretQuestionWithMessageAnswerRequiresTerminalAndMissingMetadataFailsClosed() {
        let secretViaMessage = AgentItemBody.Question(
            answerVia: "message",
            questions: [.init(id: "q1", text: "API key", secret: true)],
            answer: [.init(question: "q1", text: "sk-secret")]
        )
        #expect(secretViaMessage.requiresTerminalForSecrets(isTwoPersonChat: true))
        #expect(secretViaMessage.requiresTerminalForSecrets(isTwoPersonChat: false))
        #expect(secretViaMessage.isAnswerSecret(.init(question: "q1", text: "sk-secret")))

        let secretViaRequest = AgentItemBody.Question(
            answerVia: "request",
            questions: [.init(id: "q1", text: "API key", secret: true)]
        )
        #expect(!secretViaRequest.requiresTerminalForSecrets(isTwoPersonChat: true))
        #expect(secretViaRequest.requiresTerminalForSecrets(isTwoPersonChat: false))

        let missingMetadata = AgentItemBody.Question(
            answerVia: "request",
            questions: [.init(id: "q-nonsecret", text: "Env", secret: false)],
            answer: [.init(question: "q-missing", text: "leaked")]
        )
        #expect(missingMetadata.isAnswerSecret(.init(question: "q-missing", text: "leaked")))
        #expect(!missingMetadata.isAnswerSecret(.init(question: "q-nonsecret", text: "prod")))
    }

    @Test func agentDraftInsertionPreservesNonEmptyDraftAndSkipsActiveEdits() {
        #expect(AgentDraftInsertion.inserting("/compact", into: "", isEditingMessage: false) == "/compact")
        #expect(AgentDraftInsertion.inserting("/compact", into: "   ", isEditingMessage: false) == "/compact")
        #expect(AgentDraftInsertion.inserting("/compact", into: "existing note", isEditingMessage: false) == "existing note\n/compact")
        #expect(AgentDraftInsertion.inserting("/compact", into: "existing ", isEditingMessage: false) == "existing /compact")
        #expect(AgentDraftInsertion.inserting("/compact", into: "editing old msg", isEditingMessage: true) == nil)
        #expect(AgentDraftInsertion.inserting("   ", into: "", isEditingMessage: false) == nil)
    }

    @Test func agentSessionSelectionDoesNotSilentlySwitchWhenTargetLeavesTimeline() {
        let agentA = hex("aa")
        let agentB = hex("bb")
        let sessionB = AgentItemProjection.parse(
            messageIdHex: hex("02"),
            sender: agentB,
            item: makeAgentItem(itemType: "session", state: .running, title: "Session B", fieldsJson: #"{"type":"session","body":{}}"#),
            firstEventMissing: false,
            thread: nil,
            plaintext: "",
            tags: []
        )

        #expect(
            AgentSessionSelection.resolve(sessions: [sessionB], selectedAgentPubkeyHex: nil, initialAgentPubkeyHex: nil)
                == .selected(sessionB)
        )
        #expect(
            AgentSessionSelection.resolve(sessions: [sessionB], selectedAgentPubkeyHex: nil, initialAgentPubkeyHex: agentA)
                == .unavailable(targetPubkeyHex: agentA, alternatives: [sessionB])
        )
        #expect(
            AgentSessionSelection.resolve(sessions: [sessionB], selectedAgentPubkeyHex: agentB, initialAgentPubkeyHex: agentA)
                == .selected(sessionB)
        )
        #expect(
            AgentSessionSelection.resolve(sessions: [], selectedAgentPubkeyHex: nil, initialAgentPubkeyHex: nil)
                == .empty
        )
    }

    @MainActor
    @Test func agentInteractionStoreKeepsAmbiguousErrorPendingAndProbesStatusBeforeRetry() async throws {
        let store = AgentInteractionStore()
        let agent = hex("aa")
        let me = hex("22")
        let key = AgentInteractionStore.newSessionKey(agentPubkeyHex: agent)
        let payload = AgentRequestBuilder.newSession(agentPubkeyHex: agent)

        var sendCount = 0
        var probeStatus: LocalSendStatusFfi?
        do {
            _ = try await store.submit(
                key: key,
                summary: "New Session",
                senderAccountIdHex: me,
                payload: payload,
                checkStatus: { _ in probeStatus }
            ) { _, _ in
                sendCount += 1
                throw CancellationError()
            }
            Issue.record("Expected CancellationError to rethrow when status is unknown")
        } catch is CancellationError {}

        // Still pending while status is unknown, but controls stay enabled for recheck.
        #expect(store.isPending(key: key))
        #expect(!store.isControlDisabled(key: key))
        #expect(store.pendingRequest(forKey: key)?.statusUnknown == true)

        // If the follow-up status probe throws, keep pending and do not mint a duplicate send.
        struct ProbeError: Error {}
        _ = try await store.submit(
            key: key,
            summary: "New Session",
            senderAccountIdHex: me,
            payload: payload,
            checkStatus: { _ in throw ProbeError() }
        ) { _, _ in
            sendCount += 1
            return LocalSendAcceptanceFfi(clientToken: "t2", messageIdHex: hex("77"))
        }
        #expect(sendCount == 1)
        #expect(store.pendingRequest(forKey: key)?.statusUnknown == true)

        // Once MDK confirms rejection, a fresh submission is allowed.
        probeStatus = .rejected
        let retriedId = hex("88")
        let accepted = try await store.submit(
            key: key,
            summary: "New Session",
            senderAccountIdHex: me,
            payload: payload,
            checkStatus: { _ in probeStatus }
        ) { _, token in
            sendCount += 1
            return LocalSendAcceptanceFfi(clientToken: token, messageIdHex: retriedId)
        }
        #expect(sendCount == 2)
        #expect(accepted?.messageIdHex == retriedId)
        #expect(store.pendingRequest(forKey: key)?.statusUnknown == false)
        #expect(store.isControlDisabled(key: key))
    }

    @MainActor
    @Test func agentInteractionStoreRecoversCompletedQueuedAndEngineOwnedStatusesAndSettles() async throws {
        let store = AgentInteractionStore()
        let agent = hex("aa")
        let me = hex("22")
        let payload = AgentRequestBuilder.newSession(agentPubkeyHex: agent)

        let completedId = hex("c1")
        let completedKey = AgentInteractionStore.newSessionKey(agentPubkeyHex: agent)
        let recoveredCompleted = try await store.submit(
            key: completedKey,
            summary: "New Session",
            senderAccountIdHex: me,
            payload: payload,
            checkStatus: { _ in
                .completed(summary: SendSummaryFfi(published: 1, messageIds: [completedId]))
            }
        ) { _, _ in
            throw CancellationError()
        }
        #expect(recoveredCompleted?.messageIdHex == completedId)
        #expect(store.pendingRequest(forKey: completedKey)?.requestEventIdHex == completedId)
        #expect(store.isControlDisabled(key: completedKey))
        store.reconcile(settledEventIds: [completedId])
        #expect(!store.isPending(key: completedKey))

        let queuedId = hex("c2")
        let queuedKey = AgentInteractionStore.stopKey(agentPubkeyHex: agent, targetEventIdHex: hex("11"))
        let recoveredQueued = try await store.submit(
            key: queuedKey,
            summary: "Stop",
            senderAccountIdHex: me,
            payload: payload,
            checkStatus: { _ in .queued(messageIdHex: queuedId) }
        ) { _, _ in
            throw CancellationError()
        }
        #expect(recoveredQueued?.messageIdHex == queuedId)
        #expect(store.pendingRequest(forKey: queuedKey)?.requestEventIdHex == queuedId)

        let engineOwnedId = hex("c3")
        let engineOwnedKey = AgentInteractionStore.ownActionKey(agentPubkeyHex: agent, actionId: "compact")
        let recoveredEngineOwned = try await store.submit(
            key: engineOwnedKey,
            summary: "Compact",
            senderAccountIdHex: me,
            payload: payload,
            checkStatus: { _ in .engineOwned(messageIdHex: engineOwnedId) }
        ) { _, _ in
            throw CancellationError()
        }
        #expect(recoveredEngineOwned?.messageIdHex == engineOwnedId)
        #expect(store.pendingRequest(forKey: engineOwnedKey)?.requestEventIdHex == engineOwnedId)
    }

    @MainActor
    @Test func approvalCardRetryRecoversAmbiguousSendUsingOriginalTokenAndFreshTokenAfterRejection() async throws {
        let appState = AppState.test()
        let me = hex("22")
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "acct-1", accountIdHex: me, localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "acct-1"

        let agent = hex("aa")
        let approvalId = hex("12")
        let key = AgentInteractionStore.itemKey(targetEventIdHex: approvalId)
        let choice = AgentItemBody.ApprovalChoice(id: "c0", label: "Allow once", effect: "allow")
        let approvalProjection = AgentItemProjection.parse(
            messageIdHex: approvalId,
            sender: agent,
            item: makeAgentItem(
                itemId: "approval:1",
                itemType: "approval",
                state: .waiting,
                title: "Allow this command?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow once","effect":"allow"}]}}"#
            ),
            firstEventMissing: false,
            thread: nil,
            plaintext: "git status",
            tags: []
        )

        var capturedTokens: [String] = []
        var probedTokens: [String] = []
        var statusToReturn: LocalSendStatusFfi?
        var shouldFailSend = true

        let calls = AgentRequestCalls(
            sendCustomEvent: { _, accountRef, groupIdHex, payload, token in
                #expect(accountRef == "acct-1")
                #expect(groupIdHex == hex("bb"))
                #expect(payload.kind == MessageSemantics.kindAgentOperation)
                capturedTokens.append(token)
                if shouldFailSend {
                    throw CancellationError()
                }
                return LocalSendAcceptanceFfi(clientToken: token, messageIdHex: hex("99"))
            },
            localSendStatus: { _, accountRef, groupIdHex, token in
                #expect(accountRef == "acct-1")
                #expect(groupIdHex == hex("bb"))
                probedTokens.append(token)
                return statusToReturn
            }
        )
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "Agent Chat", id: hex("bb")),
            agentRequestCalls: calls
        )

        // Initial approval tap fails ambiguously with nil status -> card shows Pending / Retry.
        await viewModel.sendAgentApprovalChoice(choice, for: approvalProjection)
        let firstToken = try #require(capturedTokens.first)
        #expect(capturedTokens == [firstToken])
        #expect(probedTokens == [firstToken])
        #expect(viewModel.agentInteractions.pendingRequest(forKey: key)?.statusUnknown == true)
        #expect(viewModel.agentInteractions.pendingRequest(forKey: key)?.sendFailed == false)

        // Pending-row Retry when status is still `nil` reuses `firstToken` (no duplicate token).
        statusToReturn = nil
        await viewModel.recheckAgentRequestStatus(forKey: key)
        #expect(capturedTokens == [firstToken, firstToken])
        #expect(probedTokens == [firstToken, firstToken, firstToken])
        #expect(viewModel.agentInteractions.pendingRequest(forKey: key)?.statusUnknown == true)

        // When Retry succeeds on the same `nil` path, it admits under `firstToken` and clears statusUnknown.
        shouldFailSend = false
        await viewModel.recheckAgentRequestStatus(forKey: key)
        #expect(capturedTokens == [firstToken, firstToken, firstToken])
        #expect(viewModel.agentInteractions.pendingRequest(forKey: key)?.statusUnknown == false)
        #expect(viewModel.agentInteractions.pendingRequest(forKey: key)?.requestEventIdHex == hex("99"))
        #expect(viewModel.agentInteractions.isControlDisabled(key: key))

        // On a second approval where MDK explicitly reports `.rejected`, Retry mints a fresh token.
        let secondApprovalId = hex("13")
        let secondKey = AgentInteractionStore.itemKey(targetEventIdHex: secondApprovalId)
        let secondProjection = AgentItemProjection.parse(
            messageIdHex: secondApprovalId,
            sender: agent,
            item: makeAgentItem(
                itemId: "approval:2",
                itemType: "approval",
                state: .waiting,
                title: "Allow build?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow once","effect":"allow"}]}}"#
            ),
            firstEventMissing: false,
            thread: nil,
            plaintext: "swift build",
            tags: []
        )
        capturedTokens.removeAll()
        probedTokens.removeAll()
        statusToReturn = nil
        shouldFailSend = true

        await viewModel.sendAgentApprovalChoice(choice, for: secondProjection)
        let rejectedToken = try #require(capturedTokens.first)
        #expect(viewModel.agentInteractions.pendingRequest(forKey: secondKey)?.statusUnknown == true)

        statusToReturn = .rejected
        shouldFailSend = false
        await viewModel.recheckAgentRequestStatus(forKey: secondKey)
        #expect(probedTokens == [rejectedToken, rejectedToken])
        #expect(capturedTokens.count == 2)
        #expect(capturedTokens[1] != rejectedToken)
        #expect(viewModel.agentInteractions.pendingRequest(forKey: secondKey)?.requestEventIdHex == hex("99"))
    }

    @MainActor
    @Test func deletingStructuredAgentItemsMasksProjectionsAndExcludesWaitingSummaries() throws {
        let viewModel = ConversationViewModel(appState: AppState.test(), group: group(name: "Agent Chat", id: hex("bb")))
        let agent = hex("aa")
        let sessionId = hex("41")
        let turnId = hex("42")
        let mainApprovalId = hex("43")
        let taskId = hex("44")
        let childApprovalId = hex("45")
        let secretCmd = "cat /etc/secret-token"
        let threadRef = TimelineThreadRefFfi(rootMessageIdHex: taskId, parentMessageIdHex: taskId)

        let sessionRecord = timelineRecord(
            messageIdHex: sessionId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 1,
            agentItem: makeAgentItem(itemId: "s1", itemType: "session", state: .running, title: "Session", fieldsJson: #"{"type":"session","body":{}}"#)
        )
        let turnRecord = timelineRecord(
            messageIdHex: turnId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 2,
            agentItem: makeAgentItem(itemId: "t1", itemType: "turn", state: .running, title: "Working", fieldsJson: #"{"type":"turn","body":{"started_by":"user"}}"#)
        )
        let mainApprovalRecord = timelineRecord(
            messageIdHex: mainApprovalId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: secretCmd,
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 3,
            agentItem: makeAgentItem(
                itemId: "a-main",
                itemType: "approval",
                state: .waiting,
                title: "Allow?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow","effect":"allow"}]}}"#
            )
        )
        let taskRecord = timelineRecord(
            messageIdHex: taskId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Investigate",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 4,
            agentItem: makeAgentItem(
                itemId: "task:sub1",
                itemType: "task",
                state: .running,
                title: "Subagent",
                fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Investigate"}}"#
            )
        )
        let childApprovalRecord = timelineRecord(
            messageIdHex: childApprovalId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: secretCmd,
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["subagent", "task:sub1"])],
            timelineAt: 5,
            thread: threadRef,
            agentItem: makeAgentItem(
                itemId: "a-sub",
                itemType: "approval",
                state: .waiting,
                title: "Allow subagent command?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow","effect":"allow"}]}}"#,
                alerts: true
            )
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [sessionRecord, turnRecord, mainApprovalRecord, taskRecord, childApprovalRecord],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )
        #expect(viewModel.agentItemProjection(forMessageId: mainApprovalId) != nil)
        #expect(viewModel.agentItemProjection(forMessageId: childApprovalId) != nil)
        #expect(viewModel.activeRunningAgentTurns.map(\.messageIdHex) == [turnId])
        #expect(viewModel.latestAgentSessions.map(\.messageIdHex) == [sessionId])
        #expect(viewModel.waitingAgentSubagents.map(\.waiting.messageIdHex) == [childApprovalId])

        // Optimistic delete immediately masks the structured card and removes it from waiting summaries.
        viewModel.timelineStore.applyOptimisticDelete(childApprovalId)
        #expect(viewModel.isDeleted(childApprovalId))
        #expect(viewModel.agentItemProjection(forMessageId: childApprovalId) == nil)
        #expect(viewModel.waitingAgentSubagents.isEmpty)
        #expect(viewModel.subagentThreadSummary(forTaskMessageId: taskId)?.waitingInteractions.isEmpty == true)

        // Rolling back optimistic delete restores projection and waiting summary.
        viewModel.timelineStore.rollbackOptimisticDelete(childApprovalId)
        #expect(!viewModel.isDeleted(childApprovalId))
        #expect(viewModel.agentItemProjection(forMessageId: childApprovalId) != nil)
        #expect(viewModel.waitingAgentSubagents.map(\.waiting.messageIdHex) == [childApprovalId])

        // Projected deletion masks main-chat and subagent structured items and drops them from summaries.
        var deletedSession = sessionRecord
        deletedSession.deleted = true
        deletedSession.deletionSource = .admin
        var deletedTurn = turnRecord
        deletedTurn.deleted = true
        deletedTurn.deletionSource = .admin
        var deletedMainApproval = mainApprovalRecord
        deletedMainApproval.deleted = true
        deletedMainApproval.deletionSource = .admin
        var deletedChildApproval = childApprovalRecord
        deletedChildApproval.deleted = true
        deletedChildApproval.deletionSource = .admin

        viewModel.applyTimelinePage(
            TimelinePageFfi(
                messages: [deletedSession, deletedTurn, deletedMainApproval, taskRecord, deletedChildApproval],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
            placement: .window
        )
        #expect(viewModel.isDeleted(mainApprovalId))
        #expect(viewModel.agentItemProjection(forMessageId: mainApprovalId) == nil)
        #expect(viewModel.agentItemProjection(forMessageId: childApprovalId) == nil)
        #expect(viewModel.activeRunningAgentTurns.isEmpty)
        #expect(viewModel.latestAgentSessions.isEmpty)
        #expect(viewModel.waitingAgentSubagents.isEmpty)

        // Inside the subagent thread, the deleted structured item falls through to deletion presentation.
        let childItem = try #require(viewModel.subagentThreadItems(forTaskMessageId: taskId).first)
        guard case .message(let childRecord, _) = childItem.kind else {
            Issue.record("Expected message item")
            return
        }
        let display = AgentSubagentReplyPresentation.display(
            record: childRecord,
            isDeleted: viewModel.isDeleted(childRecord.messageIdHex),
            deletionSource: viewModel.deletionSource(for: childRecord.messageIdHex),
            myAccountId: viewModel.myAccountId
        )
        #expect(display.isDeleted)
        #expect(!display.text.contains(secretCmd))
    }

    @MainActor
    @Test func ambiguousAgentRequestDoesNotSendDifferentChoiceWhenStatusRecheckIsEmpty() async throws {
        let store = AgentInteractionStore()
        let agent = hex("aa")
        let me = hex("22")
        let approvalId = hex("10")
        let key = AgentInteractionStore.itemKey(targetEventIdHex: approvalId)
        let allowPayload = AgentRequestBuilder.approvalChoice(
            agentPubkeyHex: agent,
            targetEventIdHex: approvalId,
            choiceId: "c0",
            choiceLabel: "Allow once"
        )
        let denyPayload = AgentRequestBuilder.approvalChoice(
            agentPubkeyHex: agent,
            targetEventIdHex: approvalId,
            choiceId: "c1",
            choiceLabel: "Deny"
        )

        var sentTokens: [String] = []
        do {
            _ = try await store.submit(
                key: key,
                summary: "Allow once",
                senderAccountIdHex: me,
                payload: allowPayload,
                checkStatus: { _ in nil }
            ) { _, token in
                sentTokens.append(token)
                throw CancellationError()
            }
            Issue.record("Expected CancellationError")
        } catch is CancellationError {}

        #expect(sentTokens.count == 1)
        #expect(store.pendingRequest(forKey: key)?.statusUnknown == true)

        // Switching to a different choice while the prior admission is still `nil`
        // must neither reuse the old token for a different payload nor mint a second send.
        let result = try await store.submit(
            key: key,
            summary: "Deny",
            senderAccountIdHex: me,
            payload: denyPayload,
            checkStatus: { _ in nil }
        ) { _, token in
            sentTokens.append(token)
            return LocalSendAcceptanceFfi(clientToken: token, messageIdHex: hex("77"))
        }
        #expect(result == nil)
        #expect(sentTokens.count == 1)
        #expect(store.pendingRequest(forKey: key)?.statusUnknown == true)
    }

    @MainActor
    @Test(.marmotRuntimeConcurrencyLimit)
    func tailReadMarkAdvancesPastHiddenSubagentKind1111RepliesWithoutJumpingPastUnreadMainRows() async throws {
        try await withTestClient { client in
            let appState = AppState.test(
                client: client,
                notifications: AppNotifications(
                    deliveredNotificationDescriptorsProvider: { [] },
                    pendingNotificationRequestsRemover: { _ in },
                    deliveredNotificationIdentifiersRemover: { _ in }
                )
            )
            appState.activeAccountRef = "acct-1"

            let sleeper = ControlledSleeper()
            var markedIds: [String] = []
            let viewModel = ConversationViewModel(
                appState: appState,
                group: group(name: "Codex", id: hex("bb")),
                readMarkerSleep: { try await sleeper.sleep($0) },
                readMarkerMarkRead: { _, _, _, ids in
                    markedIds.append(contentsOf: ids)
                    return ids.map { TimelineReadMarkResult(messageIdHex: $0, row: nil, succeeded: true) }
                }
            )

            let agent = hex("aa")
            let blockedAuthor = hex("cc")
            let earlierMainId = hex("10")
            let taskId = hex("20")
            let unreadMainId = hex("25")
            let childReplyId = hex("30")
            let blockedReplyId = hex("40")
            let threadRef = TimelineThreadRefFfi(rootMessageIdHex: taskId, parentMessageIdHex: taskId)

            let earlierMain = timelineRecord(
                messageIdHex: earlierMainId,
                groupIdHex: hex("bb"),
                sender: agent,
                plaintext: "Starting work",
                kind: MessageSemantics.kindChat,
                timelineAt: 10
            )
            let taskRecord = timelineRecord(
                messageIdHex: taskId,
                groupIdHex: hex("bb"),
                sender: agent,
                plaintext: "Explore repo",
                kind: MessageSemantics.kindAgentActivity,
                timelineAt: 20,
                agentItem: makeAgentItem(
                    itemId: "task:sub1",
                    itemType: "task",
                    state: .running,
                    title: "Subagent",
                    fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Explore repo"}}"#
                )
            )
            let unreadMain = timelineRecord(
                messageIdHex: unreadMainId,
                groupIdHex: hex("bb"),
                sender: agent,
                plaintext: "Unread main reply below the task card",
                kind: MessageSemantics.kindChat,
                timelineAt: 25
            )
            let childReply = timelineRecord(
                messageIdHex: childReplyId,
                groupIdHex: hex("bb"),
                sender: agent,
                plaintext: "Found the root cause.",
                kind: MessageSemantics.kindComment,
                tags: [
                    MessageTagFfi(values: ["E", taskId, "", agent]),
                    MessageTagFfi(values: ["K", "1201"]),
                    MessageTagFfi(values: ["P", agent]),
                    MessageTagFfi(values: ["e", taskId, "", agent]),
                    MessageTagFfi(values: ["k", "1201"]),
                ],
                timelineAt: 30,
                thread: threadRef
            )
            let blockedReply = timelineRecord(
                messageIdHex: blockedReplyId,
                groupIdHex: hex("bb"),
                sender: blockedAuthor,
                plaintext: "Blocked reply",
                kind: MessageSemantics.kindComment,
                tags: [
                    MessageTagFfi(values: ["E", taskId, "", agent]),
                    MessageTagFfi(values: ["K", "1201"]),
                    MessageTagFfi(values: ["P", agent]),
                    MessageTagFfi(values: ["e", taskId, "", agent]),
                    MessageTagFfi(values: ["k", "1201"]),
                ],
                timelineAt: 40,
                thread: threadRef
            )

            viewModel.applyBlockedAuthors([blockedAuthor])
            viewModel.applyTimelinePage(
                TimelinePageFfi(
                    messages: [earlierMain, taskRecord, unreadMain, childReply, blockedReply],
                    hasMoreBefore: false,
                    hasMoreAfter: false
                ),
                placement: .window
            )

            // Before scrolling past unread main rows, inspecting the subagent thread
            // does not advance the watermark past unseen main-chat messages.
            viewModel.markVisibleMessagesRead([ConversationViewModel.appMessageRecord(from: earlierMain)])
            let threadItems = viewModel.subagentThreadItems(forTaskMessageId: taskId)
            #expect(threadItems.count == 1)
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [earlierMainId] && sleeper.sleepingCount == 0 }

            // Once the reader reaches the tail of the main chat, the watermark advances
            // past the hidden subagent reply (while excluding blocked authors).
            viewModel.markConversationReadThroughTail()
            try await eventually { sleeper.sleepingCount == 1 }
            sleeper.releaseAll()
            try await eventually { markedIds == [earlierMainId, childReplyId] && sleeper.sleepingCount == 0 }
        }
    }

    @MainActor
    @Test func subagentThreadDeletedKind1111ReplyHidesPlaintextInRowPresentation() throws {
        let viewModel = ConversationViewModel(appState: AppState.test(), group: group(name: "Codex", id: hex("bb")))
        let agent = hex("aa")
        let taskId = hex("20")
        let childReplyId = hex("31")
        let secretBody = "sensitive subagent output"
        let threadRef = TimelineThreadRefFfi(rootMessageIdHex: taskId, parentMessageIdHex: taskId)

        let taskRecord = timelineRecord(
            messageIdHex: taskId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Audit logs",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 10,
            agentItem: makeAgentItem(
                itemId: "task:sub1",
                itemType: "task",
                state: .done,
                title: "Subagent",
                fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Audit logs"}}"#
            )
        )
        let activeReply = timelineRecord(
            messageIdHex: childReplyId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: secretBody,
            kind: MessageSemantics.kindComment,
            tags: [
                MessageTagFfi(values: ["E", taskId, "", agent]),
                MessageTagFfi(values: ["K", "1201"]),
                MessageTagFfi(values: ["P", agent]),
                MessageTagFfi(values: ["e", taskId, "", agent]),
                MessageTagFfi(values: ["k", "1201"]),
                MessageTagFfi(values: ["phase", "commentary"]),
            ],
            timelineAt: 20,
            thread: threadRef
        )

        func resolvedDisplay() throws -> AgentSubagentReplyPresentation.Display {
            let item = try #require(viewModel.subagentThreadItems(forTaskMessageId: taskId).first)
            guard case .message(let record, _) = item.kind else {
                throw NSError(domain: "AgentItemSupportTests", code: 1)
            }
            return AgentSubagentReplyPresentation.display(
                record: record,
                isDeleted: viewModel.isDeleted(record.messageIdHex),
                deletionSource: viewModel.deletionSource(for: record.messageIdHex),
                myAccountId: viewModel.myAccountId
            )
        }

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [taskRecord, activeReply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let activeDisplay = try resolvedDisplay()
        #expect(!activeDisplay.isDeleted)
        #expect(activeDisplay.isCommentary)
        #expect(activeDisplay.text == secretBody)

        var authorDeletedReply = activeReply
        authorDeletedReply.deleted = true
        authorDeletedReply.deletionSource = .author
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [taskRecord, authorDeletedReply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let authorDeletedDisplay = try resolvedDisplay()
        #expect(authorDeletedDisplay.isDeleted)
        #expect(!authorDeletedDisplay.isCommentary)
        #expect(!authorDeletedDisplay.text.isEmpty)
        #expect(!authorDeletedDisplay.text.contains(secretBody))

        var adminDeletedReply = activeReply
        adminDeletedReply.deleted = true
        adminDeletedReply.deletionSource = .admin
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [taskRecord, adminDeletedReply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let adminDeletedDisplay = try resolvedDisplay()
        #expect(adminDeletedDisplay.isDeleted)
        #expect(!adminDeletedDisplay.text.isEmpty)
        #expect(!adminDeletedDisplay.text.contains(secretBody))
        #expect(adminDeletedDisplay.text != authorDeletedDisplay.text)
    }

    @MainActor
    @Test func kind1202SenderAttributionExpandsPastInitial200BatchForOlderApprovals() async throws {
        let appState = AppState.test()
        let responder = hex("44")
        let agent = hex("aa")
        let olderRequestId = hex("95")
        let approvalId = hex("15")
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "acct-1", accountIdHex: hex("22"), localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "acct-1"

        let newerBatch: [AppMessageRecordFfi] = (0..<200).map { index in
            message(
                id: String(format: "%064x", index + 1),
                kind: MessageSemantics.kindAgentOperation,
                groupIdHex: hex("bb"),
                sender: hex("33"),
                plaintext: "Allow",
                recordedAt: UInt64(300 + index)
            )
        }
        let olderRecord = message(
            id: olderRequestId,
            kind: MessageSemantics.kindAgentOperation,
            groupIdHex: hex("bb"),
            sender: responder,
            plaintext: "Allow once",
            recordedAt: 50
        )
        var requestedLimits: [UInt32?] = []
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "Agent Chat", id: hex("bb")),
            agentRequestCalls: AgentRequestCalls(
                sendCustomEvent: { _, _, _, _, token in
                    LocalSendAcceptanceFfi(clientToken: token, messageIdHex: hex("99"))
                },
                localSendStatus: { _, _, _, _ in nil },
                loadKind1202Messages: { _, _, _, limit in
                    requestedLimits.append(limit)
                    if let limit, limit <= 200 {
                        return newerBatch
                    }
                    return newerBatch + [olderRecord]
                }
            )
        )

        let settledApproval = timelineRecord(
            messageIdHex: approvalId,
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Answered: Allow once",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 60,
            agentItem: makeAgentItem(
                version: 2,
                itemId: "approval:old",
                itemType: "approval",
                state: .done,
                title: "Allow this command?",
                fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow once","effect":"allow"}],"answer":{"choice":"c0"}}}"#,
                settles: [olderRequestId]
            )
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [settledApproval], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        let projection = try #require(viewModel.agentItemProjection(forMessageId: approvalId))
        try await eventually {
            viewModel.agentInteractions.settledByAccountId(for: projection) == responder
        }
        #expect(requestedLimits == [200, 2_000])
    }

    @MainActor
    @Test func kind9SettlesTagSettlesPendingAgentRequestWithoutKind1201InWindow() async throws {
        let appState = AppState.test()
        let me = hex("22")
        appState.accountStore.accounts = [
            AccountSummaryFfi(label: "acct-1", accountIdHex: me, localSigning: true, signedOut: false, running: true)
        ]
        appState.activeAccountRef = "acct-1"

        let agent = hex("aa")
        let reqId = hex("91")
        let key = AgentInteractionStore.newSessionKey(agentPubkeyHex: agent)
        let viewModel = ConversationViewModel(
            appState: appState,
            group: group(name: "Agent Chat", id: hex("bb")),
            agentRequestCalls: AgentRequestCalls(
                sendCustomEvent: { _, _, _, _, token in
                    LocalSendAcceptanceFfi(clientToken: token, messageIdHex: reqId)
                },
                localSendStatus: { _, _, _, _ in nil }
            )
        )

        await viewModel.sendAgentNewSession(agentPubkeyHex: agent)
        #expect(viewModel.agentInteractions.isPending(key: key))

        // A timeline window containing zero kind-1201 items still settles via kind-9 `settles` tag.
        let reply = timelineRecord(
            messageIdHex: hex("92"),
            groupIdHex: hex("bb"),
            sender: agent,
            plaintext: "Started a fresh session.",
            kind: MessageSemantics.kindChat,
            tags: [MessageTagFfi(values: ["settles", reqId])],
            timelineAt: 50
        )
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [reply], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(!viewModel.agentInteractions.isPending(key: key))
    }

    @MainActor
    @Test func blockingAnAgentRemovesItsTurnsSessionsAndWaitingSubagentControls() {
        let viewModel = ConversationViewModel(appState: AppState.test(), group: group(name: "Agent Chat", id: hex("bb")))
        let agent = hex("aa")
        let sessionId = hex("31")
        let turnId = hex("32")
        let taskId = hex("33")
        let approvalId = hex("34")

        let sessionRecord = timelineRecord(
            messageIdHex: sessionId,
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 1,
            agentItem: makeAgentItem(itemId: "s1", itemType: "session", state: .running, title: "Session", fieldsJson: #"{"type":"session","body":{}}"#)
        )
        let turnRecord = timelineRecord(
            messageIdHex: turnId,
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 2,
            agentItem: makeAgentItem(itemId: "t1", itemType: "turn", state: .running, title: "Working", fieldsJson: #"{"type":"turn","body":{"started_by":"user"}}"#)
        )
        let taskRecord = timelineRecord(
            messageIdHex: taskId,
            sender: agent,
            plaintext: "",
            kind: MessageSemantics.kindAgentActivity,
            timelineAt: 3,
            agentItem: makeAgentItem(itemId: "sub1", itemType: "task", state: .running, title: "Explore", fieldsJson: #"{"type":"task","body":{"kind":"subagent","description":"Explore"}}"#)
        )
        let approvalRecord = timelineRecord(
            messageIdHex: approvalId,
            sender: agent,
            plaintext: "git status",
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["subagent", "sub1"])],
            timelineAt: 4,
            agentItem: makeAgentItem(itemId: "a1", itemType: "approval", state: .waiting, title: "Allow?", fieldsJson: #"{"type":"approval","body":{"choices":[{"id":"c0","label":"Allow","effect":"allow"}]}}"#)
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [sessionRecord, turnRecord, taskRecord, approvalRecord], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        #expect(viewModel.activeRunningAgentTurns.map(\.messageIdHex) == [turnId])
        #expect(viewModel.latestAgentSessions.map(\.messageIdHex) == [sessionId])
        #expect(viewModel.waitingAgentSubagents.map(\.task.messageIdHex) == [taskId])

        viewModel.applyBlockedAuthors([agent])
        #expect(viewModel.activeRunningAgentTurns.isEmpty)
        #expect(viewModel.latestAgentSessions.isEmpty)
        #expect(viewModel.waitingAgentSubagents.isEmpty)
    }

    // MARK: - Helpers

    private func makeAgentItem(
        version: UInt64 = 1,
        itemId: String = "i1",
        itemType: String,
        state: AgentItemStateFfi,
        title: String,
        fieldsJson: String,
        settles: [String] = [],
        alerts: Bool = false
    ) -> AgentItemFfi {
        AgentItemFfi(
            version: version,
            state: state,
            title: title,
            harness: "codex",
            itemId: itemId,
            seq: 1,
            itemType: itemType,
            fieldsJson: fieldsJson,
            session: "s1",
            turn: "t1",
            startedByMessageIdHex: nil,
            settles: settles,
            alerts: alerts
        )
    }

    private func decodeJSONObject(_ raw: String?) throws -> [String: Any] {
        let string = try #require(raw)
        let data = try #require(string.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

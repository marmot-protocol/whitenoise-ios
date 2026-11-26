import Foundation
import MarmotKit

/// Parsed view of a structured agent item (kind 1201, `TimelineMessageRecordFfi.agentItem`).
///
/// Mirrors `marmot-agent-events/src/body.rs` and `marmot-agent/src/carrier.rs`.
/// Privacy invariant (D-071): `CustomDebugStringConvertible` implementations print
/// only structural metadata, never user text, commands, diffs, keys, or group ids.
nonisolated struct AgentItemProjection: Equatable, Sendable, CustomDebugStringConvertible {
    let messageIdHex: String
    let sender: String
    let item: AgentItemFfi
    let firstEventMissing: Bool
    let thread: TimelineThreadRefFfi?
    let plaintext: String
    let body: AgentItemBody
    let cuts: [AgentItemCutNotice]
    let subagentTag: String?

    var debugDescription: String {
        "AgentItemProjection(type: \(item.itemType), state: \(item.state), v: \(item.version), missingFirst: \(firstEventMissing))"
    }

    var isSubagentTask: Bool {
        if case .task(let task) = body {
            return task.kind == "subagent"
        }
        return false
    }

    var isWaitingInteraction: Bool {
        guard item.state == .waiting else { return false }
        switch body {
        case .approval, .question:
            return true
        default:
            return false
        }
    }

    var sanitizedTitle: String {
        ContentSanitizer.compactSingleLine(item.title, maxLength: 140)
            ?? item.itemType.capitalized
    }

    /// Label for a subagent task row (matching `marmot-agent-chat`'s `task_label`).
    var subagentTaskLabel: String {
        if case .task(let task) = body,
           let desc = ContentSanitizer.compactSingleLine(task.description, maxLength: 140),
           !desc.isEmpty {
            return desc
        }
        for line in plaintext.split(whereSeparator: \.isNewline) {
            if let cleaned = ContentSanitizer.compactSingleLine(String(line), maxLength: 140), !cleaned.isEmpty {
                return cleaned
            }
        }
        return sanitizedTitle
    }

    static func parse(
        messageIdHex: String,
        sender: String,
        item: AgentItemFfi,
        firstEventMissing: Bool,
        thread: TimelineThreadRefFfi?,
        plaintext: String,
        tags: [MessageTagFfi]
    ) -> AgentItemProjection {
        let body = AgentItemBody.parse(fieldsJson: item.fieldsJson, expectedType: item.itemType)
        let cuts = AgentItemCutNotice.parse(from: tags)
        let subagentTag = MessageSemantics.agentSubagentTaskId(in: tags)
        return AgentItemProjection(
            messageIdHex: messageIdHex,
            sender: sender,
            item: item,
            firstEventMissing: firstEventMissing,
            thread: thread,
            plaintext: plaintext,
            body: body,
            cuts: cuts,
            subagentTag: subagentTag
        )
    }
}

/// Truncation / left-out markers carried on `cut` and `left_out` tags of kind 1201.
nonisolated struct AgentItemCutNotice: Equatable, Hashable, Sendable {
    let field: String
    let value: Int

    var displayLabel: String {
        switch field {
        case "output":
            return L10n.formatted("Output truncated (%@ total)", ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))
        case "diffs":
            return L10n.plural("%lld diffs truncated", Int64(value))
        case "changes":
            return L10n.plural("Changes trimmed (%lld total)", Int64(value))
        case "entries":
            return L10n.plural("Plan steps trimmed (%lld total)", Int64(value))
        case "descriptions":
            return L10n.plural("%lld command descriptions omitted", Int64(value))
        case "item":
            return L10n.formatted("Item too large to show (%@)", ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))
        default:
            return L10n.formatted("%@ truncated", field.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    static func parse(from tags: [MessageTagFfi]) -> [AgentItemCutNotice] {
        tags.compactMap { tag in
            guard tag.values.count >= 3,
                  tag.values[0] == "cut",
                  let amount = Int(tag.values[2])
            else { return nil }
            return AgentItemCutNotice(field: tag.values[1], value: amount)
        }
    }
}

nonisolated enum AgentItemBody: Equatable, Sendable, CustomDebugStringConvertible {
    case turn(Turn)
    case message(Message)
    case reasoning
    case tool(Tool)
    case approval(Approval)
    case question(Question)
    case plan(Plan)
    case task(TaskBody)
    case notice(Notice)
    case error(ErrorBody)
    case session(Session)
    case unknown

    var debugDescription: String {
        switch self {
        case .turn: "AgentItemBody.turn"
        case .message: "AgentItemBody.message"
        case .reasoning: "AgentItemBody.reasoning"
        case .tool(let t): "AgentItemBody.tool(\(t.kind.rawValue))"
        case .approval: "AgentItemBody.approval"
        case .question: "AgentItemBody.question"
        case .plan: "AgentItemBody.plan"
        case .task: "AgentItemBody.task"
        case .notice(let n): "AgentItemBody.notice(\(n.kind))"
        case .error: "AgentItemBody.error"
        case .session: "AgentItemBody.session"
        case .unknown: "AgentItemBody.unknown"
        }
    }

    struct Turn: Equatable, Sendable, Decodable {
        let startedBy: String?
        let durationMs: UInt64?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case startedBy = "started_by"
            case durationMs = "duration_ms"
            case usage
        }
    }

    struct Usage: Equatable, Sendable, Decodable {
        let inputTokens: UInt64?
        let outputTokens: UInt64?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct Message: Equatable, Sendable, Decodable {
        let phase: String?
        let parent: String?
    }

    enum ToolKind: String, Equatable, Sendable, Decodable {
        case command
        case edit
        case read
        case search
        case fetch
        case mcp
        case subagent
        case other

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = ToolKind(rawValue: raw) ?? .other
        }
    }

    struct ToolChange: Equatable, Sendable, Decodable, Identifiable {
        let path: String
        let diff: String
        let change: String?

        var id: String { "\(path):\(change ?? ""):\(diff.count)" }
    }

    struct Tool: Equatable, Sendable, Decodable {
        let kind: ToolKind
        let name: String
        let command: String?
        let cwd: String?
        let exitCode: Int64?
        let durationMs: UInt64?
        let output: String?
        let changes: [ToolChange]
        let query: String?
        let path: String?
        let inputPrettyJson: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case kind, name, command, cwd
            case exitCode = "exit_code"
            case durationMs = "duration_ms"
            case output, changes, query, path, input, error
        }

        init(
            kind: ToolKind,
            name: String,
            command: String? = nil,
            cwd: String? = nil,
            exitCode: Int64? = nil,
            durationMs: UInt64? = nil,
            output: String? = nil,
            changes: [ToolChange] = [],
            query: String? = nil,
            path: String? = nil,
            inputPrettyJson: String? = nil,
            error: String? = nil
        ) {
            self.kind = kind
            self.name = name
            self.command = command
            self.cwd = cwd
            self.exitCode = exitCode
            self.durationMs = durationMs
            self.output = output
            self.changes = changes
            self.query = query
            self.path = path
            self.inputPrettyJson = inputPrettyJson
            self.error = error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? container.decode(ToolKind.self, forKey: .kind)) ?? .other
            name = (try? container.decode(String.self, forKey: .name)) ?? ""
            command = try? container.decodeIfPresent(String.self, forKey: .command)
            cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
            exitCode = try? container.decodeIfPresent(Int64.self, forKey: .exitCode)
            durationMs = try? container.decodeIfPresent(UInt64.self, forKey: .durationMs)
            output = try? container.decodeIfPresent(String.self, forKey: .output)
            changes = (try? container.decodeIfPresent([ToolChange].self, forKey: .changes)) ?? []
            query = try? container.decodeIfPresent(String.self, forKey: .query)
            path = try? container.decodeIfPresent(String.self, forKey: .path)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
            if let anyValue = try? container.decodeIfPresent(JSONAnyValue.self, forKey: .input) {
                inputPrettyJson = anyValue.prettyPrinted
            } else {
                inputPrettyJson = nil
            }
        }
    }

    struct ApprovalChoice: Equatable, Sendable, Decodable, Identifiable {
        let id: String
        let label: String
        let effect: String // "allow" or "deny"

        var isAllow: Bool { effect == "allow" }
        var isDeny: Bool { effect == "deny" }
    }

    struct ApprovalAnswer: Equatable, Sendable, Decodable {
        let choice: String?
    }

    struct Approval: Equatable, Sendable, Decodable {
        let subject: String?
        let choices: [ApprovalChoice]
        let answer: ApprovalAnswer?

        enum CodingKeys: String, CodingKey {
            case subject, choices, answer
        }

        init(subject: String? = nil, choices: [ApprovalChoice] = [], answer: ApprovalAnswer? = nil) {
            self.subject = subject
            self.choices = choices
            self.answer = answer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subject = try? container.decodeIfPresent(String.self, forKey: .subject)
            choices = (try? container.decodeIfPresent([ApprovalChoice].self, forKey: .choices)) ?? []
            answer = try? container.decodeIfPresent(ApprovalAnswer.self, forKey: .answer)
        }
    }

    struct OfferedOption: Equatable, Sendable, Decodable, Identifiable {
        let id: String
        let label: String
        let description: String?
    }

    struct AskedQuestion: Equatable, Sendable, Decodable, Identifiable {
        let id: String
        let header: String?
        let text: String
        let options: [OfferedOption]
        let multiple: Bool
        let allowText: Bool
        let secret: Bool

        enum CodingKeys: String, CodingKey {
            case id, header, text, options, multiple
            case allowText = "allow_text"
            case secret
        }

        init(
            id: String,
            header: String? = nil,
            text: String,
            options: [OfferedOption] = [],
            multiple: Bool = false,
            allowText: Bool = false,
            secret: Bool = false
        ) {
            self.id = id
            self.header = header
            self.text = text
            self.options = options
            self.multiple = multiple
            self.allowText = allowText
            self.secret = secret
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            header = try? container.decodeIfPresent(String.self, forKey: .header)
            text = try container.decode(String.self, forKey: .text)
            options = (try? container.decodeIfPresent([OfferedOption].self, forKey: .options)) ?? []
            multiple = (try? container.decodeIfPresent(Bool.self, forKey: .multiple)) ?? false
            allowText = (try? container.decodeIfPresent(Bool.self, forKey: .allowText)) ?? false
            secret = (try? container.decodeIfPresent(Bool.self, forKey: .secret)) ?? false
        }
    }

    struct AnsweredQuestion: Equatable, Sendable, Decodable {
        let question: String
        let options: [String]
        let text: String?

        enum CodingKeys: String, CodingKey {
            case question, options, text
        }

        init(question: String, options: [String] = [], text: String? = nil) {
            self.question = question
            self.options = options
            self.text = text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            question = try container.decode(String.self, forKey: .question)
            options = (try? container.decodeIfPresent([String].self, forKey: .options)) ?? []
            text = try? container.decodeIfPresent(String.self, forKey: .text)
        }
    }

    struct Question: Equatable, Sendable, Decodable {
        let answerVia: String // "request" or "message"
        let subject: String?
        let questions: [AskedQuestion]
        let answer: [AnsweredQuestion]?

        var isAnsweredByMessage: Bool { answerVia == "message" }
        var hasSecretQuestion: Bool { questions.contains(where: \.secret) }

        enum CodingKeys: String, CodingKey {
            case answerVia = "answer_via"
            case subject, questions, answer
        }

        init(
            answerVia: String = "request",
            subject: String? = nil,
            questions: [AskedQuestion] = [],
            answer: [AnsweredQuestion]? = nil
        ) {
            self.answerVia = answerVia
            self.subject = subject
            self.questions = questions
            self.answer = answer
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            answerVia = (try? container.decodeIfPresent(String.self, forKey: .answerVia)) ?? "request"
            subject = try? container.decodeIfPresent(String.self, forKey: .subject)
            questions = (try? container.decodeIfPresent([AskedQuestion].self, forKey: .questions)) ?? []
            answer = try? container.decodeIfPresent([AnsweredQuestion].self, forKey: .answer)
        }
    }

    struct PlanEntry: Equatable, Sendable, Decodable, Identifiable {
        let text: String
        let state: String // "pending", "running", "done"

        var id: String { "\(state):\(text)" }
    }

    struct Plan: Equatable, Sendable, Decodable {
        let text: String?
        let entries: [PlanEntry]

        enum CodingKeys: String, CodingKey {
            case text, entries
        }

        init(text: String? = nil, entries: [PlanEntry] = []) {
            self.text = text
            self.entries = entries
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try? container.decodeIfPresent(String.self, forKey: .text)
            entries = (try? container.decodeIfPresent([PlanEntry].self, forKey: .entries)) ?? []
        }
    }

    struct TaskBody: Equatable, Sendable, Decodable {
        let kind: String
        let description: String?
        let subject: String?
    }

    struct Notice: Equatable, Sendable, Decodable {
        let kind: String
        let durationMs: UInt64?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case durationMs = "duration_ms"
            case reason
        }
    }

    struct ErrorBody: Equatable, Sendable, Decodable {
        let request: String?
        let code: Int64?
        let willRetry: Bool?

        enum CodingKeys: String, CodingKey {
            case request, code
            case willRetry = "will_retry"
        }
    }

    struct SessionSetting: Equatable, Sendable, Decodable, Identifiable {
        let id: String
        let label: String
        let value: String?
        let options: [String]?
        let approve: Bool

        enum CodingKeys: String, CodingKey {
            case id, label, value, options, approve
        }

        init(id: String, label: String, value: String? = nil, options: [String]? = nil, approve: Bool = false) {
            self.id = id
            self.label = label
            self.value = value
            self.options = options
            self.approve = approve
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = try container.decode(String.self, forKey: .label)
            value = try? container.decodeIfPresent(String.self, forKey: .value)
            options = try? container.decodeIfPresent([String].self, forKey: .options)
            approve = (try? container.decodeIfPresent(Bool.self, forKey: .approve)) ?? false
        }
    }

    struct SessionAction: Equatable, Sendable, Decodable, Identifiable {
        let id: String
        let label: String
        let description: String?
    }

    struct SessionCommand: Equatable, Sendable, Decodable, Identifiable {
        let name: String
        let description: String?
        let hint: String

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, description, hint
        }

        init(name: String, description: String? = nil, hint: String = "") {
            self.name = name
            self.description = description
            self.hint = hint
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            hint = (try? container.decodeIfPresent(String.self, forKey: .hint)) ?? ""
        }
    }

    struct Session: Equatable, Sendable, Decodable {
        let harnessVersion: String
        let settings: [SessionSetting]
        let actions: [SessionAction]
        let commands: [SessionCommand]

        enum CodingKeys: String, CodingKey {
            case harnessVersion = "harness_version"
            case settings, actions, commands
        }

        init(
            harnessVersion: String = "",
            settings: [SessionSetting] = [],
            actions: [SessionAction] = [],
            commands: [SessionCommand] = []
        ) {
            self.harnessVersion = harnessVersion
            self.settings = settings
            self.actions = actions
            self.commands = commands
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            harnessVersion = (try? container.decodeIfPresent(String.self, forKey: .harnessVersion)) ?? ""
            settings = (try? container.decodeIfPresent([SessionSetting].self, forKey: .settings)) ?? []
            actions = (try? container.decodeIfPresent([SessionAction].self, forKey: .actions)) ?? []
            commands = (try? container.decodeIfPresent([SessionCommand].self, forKey: .commands)) ?? []
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let body: AnyDecodableBody?

        enum CodingKeys: String, CodingKey {
            case type, body
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            body = nil
        }
    }

    private struct AnyDecodableBody: Decodable {}

    private struct TypedEnvelope<T: Decodable>: Decodable {
        let type: String
        let body: T
    }

    /// Cap raw JSON decode to MDK's 64 KB agent-event ceiling so hostile inputs
    /// never stall the MainActor.
    static let maxFieldsJsonBytes = 64 * 1024

    static func parse(fieldsJson: String, expectedType: String) -> AgentItemBody {
        guard fieldsJson.utf8.count <= maxFieldsJsonBytes,
              let data = fieldsJson.data(using: .utf8)
        else { return .unknown }
        let decoder = JSONDecoder()
        let wireType = (try? decoder.decode(Envelope.self, from: data))?.type ?? expectedType
        switch wireType {
        case "turn":
            guard let env = try? decoder.decode(TypedEnvelope<Turn>.self, from: data) else { return .unknown }
            return .turn(env.body)
        case "message":
            guard let env = try? decoder.decode(TypedEnvelope<Message>.self, from: data) else { return .unknown }
            return .message(env.body)
        case "reasoning":
            return .reasoning
        case "tool":
            guard let env = try? decoder.decode(TypedEnvelope<Tool>.self, from: data) else { return .unknown }
            return .tool(env.body)
        case "approval":
            guard let env = try? decoder.decode(TypedEnvelope<Approval>.self, from: data) else { return .unknown }
            return .approval(env.body)
        case "question":
            guard let env = try? decoder.decode(TypedEnvelope<Question>.self, from: data) else { return .unknown }
            return .question(env.body)
        case "plan":
            guard let env = try? decoder.decode(TypedEnvelope<Plan>.self, from: data) else { return .unknown }
            return .plan(env.body)
        case "task":
            guard let env = try? decoder.decode(TypedEnvelope<TaskBody>.self, from: data) else { return .unknown }
            return .task(env.body)
        case "notice":
            guard let env = try? decoder.decode(TypedEnvelope<Notice>.self, from: data) else { return .unknown }
            return .notice(env.body)
        case "error":
            guard let env = try? decoder.decode(TypedEnvelope<ErrorBody>.self, from: data) else { return .unknown }
            return .error(env.body)
        case "session":
            guard let env = try? decoder.decode(TypedEnvelope<Session>.self, from: data) else { return .unknown }
            return .session(env.body)
        default:
            return .unknown
        }
    }
}

/// Arbitrary JSON value decoder for `tool.input` pretty-printing.
private nonisolated enum JSONAnyValue: Equatable, Sendable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONAnyValue])
    case array([JSONAnyValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONAnyValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONAnyValue].self) {
            self = .object(dict)
        } else {
            self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(\.foundationObject)
        case .object(let d): d.mapValues(\.foundationObject)
        }
    }

    var prettyPrinted: String? {
        if case .string(let s) = self { return s }
        let obj = foundationObject
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }
}

// MARK: - Kind 1202 Request Builder

nonisolated struct AgentQuestionReplyPayload: Equatable, Sendable, Encodable {
    let question: String
    let options: [String]
    let text: String?

    enum CodingKeys: String, CodingKey {
        case question, options, text
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(options, forKey: .options)
        if let text {
            try container.encode(text, forKey: .text)
        }
    }
}

nonisolated struct AgentRequestPayload: Equatable, Sendable {
    let kind: UInt64
    let tags: [[String]]
    let content: String
}

/// Builds kind 1202 answer & control events per `docs/design/agent-kinds.md` and `carrier.rs`.
nonisolated enum AgentRequestBuilder {
    static let requestKind: UInt64 = MessageSemantics.kindAgentOperation // 1202

    static func approvalChoice(
        agentPubkeyHex: String,
        targetEventIdHex: String,
        choiceId: String,
        choiceLabel: String
    ) -> AgentRequestPayload {
        let details = encodeJSON(ChoiceDetails(action: "choice", choice: choiceId))
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: targetEventIdHex,
            detailsJson: details,
            content: choiceLabel
        )
    }

    static func questionAnswers(
        agentPubkeyHex: String,
        targetEventIdHex: String,
        answers: [AgentQuestionReplyPayload],
        containsSecret: Bool,
        nonSecretSummary: String? = nil
    ) -> AgentRequestPayload {
        let details = encodeJSON(QuestionsDetails(action: "questions", questions: answers))
        // D-041: never place a secret answer in the plain content field.
        let content: String
        if containsSecret {
            content = "Answered"
        } else if let summary = nonSecretSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            content = summary
        } else {
            content = "Answered"
        }
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: targetEventIdHex,
            detailsJson: details,
            content: content
        )
    }

    static func interrupt(
        agentPubkeyHex: String,
        targetEventIdHex: String?
    ) -> AgentRequestPayload {
        let details = encodeJSON(ActionOnlyDetails(action: "interrupt"))
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: targetEventIdHex,
            detailsJson: details,
            content: "Stop"
        )
    }

    static func newSession(agentPubkeyHex: String) -> AgentRequestPayload {
        let details = encodeJSON(ActionOnlyDetails(action: "new_session"))
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: nil,
            detailsJson: details,
            content: "New session"
        )
    }

    static func setSetting(
        agentPubkeyHex: String,
        settingId: String,
        value: String,
        label: String? = nil
    ) -> AgentRequestPayload {
        let details = encodeJSON(SetDetails(action: "set", setting: settingId, value: value))
        let displayName = label ?? settingId
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: nil,
            detailsJson: details,
            content: "\(displayName): \(value)"
        )
    }

    static func ownAction(
        agentPubkeyHex: String,
        actionId: String,
        label: String
    ) -> AgentRequestPayload {
        let details = encodeJSON(OwnDetails(action: "own", id: actionId))
        return build(
            agentPubkeyHex: agentPubkeyHex,
            targetEventIdHex: nil,
            detailsJson: details,
            content: label
        )
    }

    private static func build(
        agentPubkeyHex: String,
        targetEventIdHex: String?,
        detailsJson: String,
        content: String
    ) -> AgentRequestPayload {
        var tags: [[String]] = [
            ["p", agentPubkeyHex],
            ["details", detailsJson],
        ]
        if let targetEventIdHex, !targetEventIdHex.isEmpty {
            tags.append(["e", targetEventIdHex])
        }
        return AgentRequestPayload(kind: requestKind, tags: tags, content: content)
    }

    private struct ChoiceDetails: Encodable {
        let action: String
        let choice: String
    }

    private struct QuestionsDetails: Encodable {
        let action: String
        let questions: [AgentQuestionReplyPayload]
    }

    private struct ActionOnlyDetails: Encodable {
        let action: String
    }

    private struct SetDetails: Encodable {
        let action: String
        let setting: String
        let value: String
    }

    private struct OwnDetails: Encodable {
        let action: String
        let id: String
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

// MARK: - Secret Question Privacy Policy (D-041)

nonisolated enum AgentQuestionPrivacyPolicy {
    /// A secret question can only be answered from the chat when the chat has
    /// exactly two members (the person and the agent). When member count is
    /// unknown (<= 0) or > 2, fail safe and direct the user to the terminal.
    static func canAnswerSecretQuestionInChat(memberCount: Int) -> Bool {
        memberCount == 2
    }
}

// MARK: - Formatting helpers

nonisolated enum AgentItemFormatting {
    static func durationString(milliseconds: UInt64) -> String {
        if milliseconds < 1_000 {
            return "\(milliseconds)ms"
        }
        let totalSeconds = Double(milliseconds) / 1_000.0
        if totalSeconds < 60 {
            return String(format: "%.1fs", totalSeconds)
        }
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        return "\(minutes)m \(seconds)s"
    }

    static func tokenCountString(_ count: UInt64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    static func stateLabel(_ state: AgentItemStateFfi) -> String {
        switch state {
        case .running: L10n.string("Running")
        case .waiting: L10n.string("Waiting")
        case .done: L10n.string("Done")
        case .failed: L10n.string("Failed")
        case .declined: L10n.string("Declined")
        case .cancelled: L10n.string("Cancelled")
        }
    }
}

// MARK: - Subagent Thread Partitioning

/// Summary of one subagent `task` row's thread contents.
nonisolated struct AgentSubagentThreadSummary: Equatable, Sendable {
    let taskMessageIdHex: String
    /// Total rows (items + words) belonging to this subagent's thread tree.
    let totalEntryCount: Int
    /// Direct child message ids belonging to this task's thread view (including nested tasks).
    let directChildMessageIds: [String]
    /// Any waiting approval or question anywhere inside this subagent's subtree.
    let waitingInteractions: [AgentItemProjection]
}

/// Pure projection that partitions loaded timeline records into subagent threads
/// rooted at `task` items (`body.kind == "subagent"`), supporting arbitrary nesting
/// per `docs/design/subagents.md`.
nonisolated struct AgentSubagentThreadIndex: Equatable, Sendable {
    /// Message IDs that belong inside a loaded subagent `task` thread and should
    /// therefore be hidden from the main chat timeline (they appear inside the thread).
    let hiddenFromMainTimeline: Set<String>
    /// Thread summary keyed by each subagent `task` item's `messageIdHex`.
    let summariesByTaskMessageId: [String: AgentSubagentThreadSummary]

    static let empty = AgentSubagentThreadIndex(
        hiddenFromMainTimeline: [],
        summariesByTaskMessageId: [:]
    )

    static func build(
        orderedMessageIds: [String],
        agentItemsByMessageId: [String: AgentItemProjection],
        threadRefByMessageId: [String: TimelineThreadRefFfi],
        senderByMessageId: [String: String]
    ) -> AgentSubagentThreadIndex {
        // 1. Identify all loaded subagent `task` items.
        var subagentTaskIds: Set<String> = []
        var taskMessageIdBySenderAndItemId: [String: String] = [:]
        for messageId in orderedMessageIds {
            guard let projection = agentItemsByMessageId[messageId], projection.isSubagentTask else { continue }
            subagentTaskIds.insert(messageId)
            taskMessageIdBySenderAndItemId["\(projection.sender)|\(projection.item.itemId)"] = messageId
        }
        guard !subagentTaskIds.isEmpty else { return .empty }

        // 2. For every message, determine which immediate subagent `task` owns it (if any).
        //    Follows `docs/design/subagents.md`:
        //    - If the row has a `subagent` tag naming a loaded task of the same sender, use it.
        //    - Else walk `thread.parentMessageIdHex` up to the nearest loaded subagent task,
        //      falling back to `thread.rootMessageIdHex` if it is a loaded subagent task.
        var directParentTaskByMessageId: [String: String] = [:]
        var rootTaskByMessageId: [String: String] = [:]

        func resolveParentTask(for messageId: String) -> String? {
            if let cached = directParentTaskByMessageId[messageId] { return cached }
            // Check `subagent` tag on agent items first (handles edits whose `e` is target, not parent).
            if let projection = agentItemsByMessageId[messageId],
               let subTag = projection.subagentTag,
               let ownerTask = taskMessageIdBySenderAndItemId["\(projection.sender)|\(subTag)"],
               ownerTask != messageId {
                return ownerTask
            }
            guard let thread = threadRefByMessageId[messageId] else { return nil }
            // Walk parent chain (bounded to avoid cycles from malformed data).
            var current: String? = thread.parentMessageIdHex
            var visited: Set<String> = [messageId]
            var steps = 0
            while let candidate = current, steps < 32 {
                steps += 1
                if subagentTaskIds.contains(candidate) {
                    return candidate
                }
                if visited.contains(candidate) { break }
                visited.insert(candidate)
                current = threadRefByMessageId[candidate]?.parentMessageIdHex
            }
            if subagentTaskIds.contains(thread.rootMessageIdHex), thread.rootMessageIdHex != messageId {
                return thread.rootMessageIdHex
            }
            return nil
        }

        for messageId in orderedMessageIds {
            if let ownerTask = resolveParentTask(for: messageId) {
                directParentTaskByMessageId[messageId] = ownerTask
                if let root = threadRefByMessageId[messageId]?.rootMessageIdHex, subagentTaskIds.contains(root) {
                    rootTaskByMessageId[messageId] = root
                } else {
                    rootTaskByMessageId[messageId] = ownerTask
                }
            }
        }

        // 3. Collect direct children, total subtree counts, and waiting interactions
        //    propagated up every ancestor task (so a waiting approval in a nested
        //    subagent also surfaces on the top-level subagent row in the main chat).
        var directChildren: [String: [String]] = [:]
        var subtreeCounts: [String: Int] = [:]
        var waitingByTask: [String: [AgentItemProjection]] = [:]
        var hiddenFromMain: Set<String> = []

        for messageId in orderedMessageIds {
            guard let ownerTask = directParentTaskByMessageId[messageId] else { continue }
            hiddenFromMain.insert(messageId)
            directChildren[ownerTask, default: []].append(messageId)

            let waitingProjection: AgentItemProjection? = {
                guard let proj = agentItemsByMessageId[messageId], proj.isWaitingInteraction else { return nil }
                return proj
            }()

            // Walk ancestor task chain so counts & waiting approvals bubble up.
            var ancestor: String? = ownerTask
            var visited: Set<String> = []
            var depth = 0
            while let taskId = ancestor, depth < 16 {
                depth += 1
                if visited.contains(taskId) { break }
                visited.insert(taskId)
                subtreeCounts[taskId, default: 0] += 1
                if let waitingProjection {
                    waitingByTask[taskId, default: []].append(waitingProjection)
                }
                ancestor = directParentTaskByMessageId[taskId]
            }
        }

        var summaries: [String: AgentSubagentThreadSummary] = [:]
        for taskId in subagentTaskIds {
            summaries[taskId] = AgentSubagentThreadSummary(
                taskMessageIdHex: taskId,
                totalEntryCount: subtreeCounts[taskId] ?? 0,
                directChildMessageIds: directChildren[taskId] ?? [],
                waitingInteractions: waitingByTask[taskId] ?? []
            )
        }

        return AgentSubagentThreadIndex(
            hiddenFromMainTimeline: hiddenFromMain,
            summariesByTaskMessageId: summaries
        )
    }
}

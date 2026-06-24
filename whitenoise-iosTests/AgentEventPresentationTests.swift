import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct AgentEventPresentationTests {
    @Test func activityDisplayUsesJsonTextAndStatusTag() {
        let record = agentRecord(
            kind: MessageSemantics.kindAgentActivity,
            plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
            tags: [MessageTagFfi(values: ["status", "thinking"])]
        )

        let display = AgentEventPresentation.display(for: record)

        #expect(display?.kind == .activity)
        #expect(display?.primaryText == "Thinking")
        #expect(display?.iconName == "ellipsis.message")
    }

    @Test func operationDisplayPrefersTextAndFallsBackToPreview() {
        let record = agentRecord(
            kind: MessageSemantics.kindAgentOperation,
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","name":"delegate_task","preview":"Search for and summarize the latest b...","text":"🔀 delegate_task: \"Search...\""}"#,
            tags: [
                MessageTagFfi(values: ["operation", "tool_call"]),
                MessageTagFfi(values: ["operation-status", "started"]),
                MessageTagFfi(values: ["operation-name", "delegate_task"]),
            ]
        )

        let display = AgentEventPresentation.display(for: record)

        #expect(display?.kind == .operation)
        #expect(display?.primaryText == "🔀 delegate_task: \"Search...\"")
        #expect(display?.secondaryText == "delegate task")
        #expect(display?.iconName == "wrench.and.screwdriver")
    }

    @Test func previewTextFallsBackToPreviewWhenTextMissing() {
        let text = AgentEventPresentation.previewText(
            from: #"{"v":1,"preview":"Search for and summarize the latest b..."}"#
        )
        #expect(text == "Search for and summarize the latest b...")
    }

    @Test func primaryTextStripsBidiAndZeroWidthSpoofingCodepoints() {
        // RLO (U+202E) bidirectional override, LRM (U+200E), zero-width space
        // (U+200B), and BOM/ZWNBSP (U+FEFF) embedded in peer JSON `text` must
        // be stripped before display (Trojan-Source-style spoofing). JSON
        // `\uXXXX` escapes decode to the real codepoints when parsed.
        let record = agentRecord(
            kind: MessageSemantics.kindAgentActivity,
            plaintext: #"{"v":1,"status":"running","text":"safe\u202etxet desrever\u200b\u200e\ufeff"}"#,
            tags: []
        )

        let display = AgentEventPresentation.display(for: record)

        for scalar: Unicode.Scalar in ["\u{202E}", "\u{200B}", "\u{200E}", "\u{FEFF}"] {
            #expect(display?.primaryText.unicodeScalars.contains(scalar) == false)
        }
        #expect(display?.primaryText.isEmpty == false)
    }

    @Test func primaryTextIsLengthBounded() {
        // An unbounded peer `text` must be capped so a single row can't flood
        // the timeline.
        let long = String(repeating: "A", count: 5_000)
        let record = agentRecord(
            kind: MessageSemantics.kindAgentActivity,
            plaintext: #"{"v":1,"status":"running","text":"\#(long)"}"#,
            tags: []
        )

        let display = AgentEventPresentation.display(for: record)

        #expect((display?.primaryText.count ?? .max) <= AgentEventPresentation.maxPrimaryTextLength)
    }

    @Test func secondaryOperationNameStripsBidiAndIsLengthBounded() {
        // The operation-name secondary line is also peer-controlled and must be
        // sanitized + bounded (a fix that only covers the primary line leaves
        // this exposed).
        let longName = String(repeating: "b", count: 5_000)
        let record = agentRecord(
            kind: MessageSemantics.kindAgentOperation,
            plaintext: #"{"v":1,"event_type":"tool_call","text":"op","name":"do\u202e_\#(longName)"}"#,
            tags: []
        )

        let display = AgentEventPresentation.display(for: record)

        #expect(display?.secondaryText?.unicodeScalars.contains("\u{202E}") == false)
        #expect((display?.secondaryText?.count ?? .max) <= AgentEventPresentation.maxSecondaryTextLength)
    }

    @Test func previewTextStripsBidiSpoofingCodepoints() {
        // The chat-list preview path also routes through the same projection,
        // so it inherits the sanitization.
        let text = AgentEventPresentation.previewText(
            from: #"{"v":1,"preview":"hi\u202eybab\u200b"}"#
        )
        #expect(text?.unicodeScalars.contains("\u{202E}") == false)
        #expect(text?.unicodeScalars.contains("\u{200B}") == false)
    }

    @MainActor
    @Test func agentOperationTimelineRowIsVisibleWithoutStreamingDebug() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testAgentGroup()
        )
        let operation = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            tags: [MessageTagFfi(values: ["operation", "tool_call"])],
            timelineAt: 1
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [operation], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, _) = viewModel.timeline.first?.kind else {
            Issue.record("Expected an agent operation message row")
            return
        }
        #expect(record.kind == MessageSemantics.kindAgentOperation)
    }
}

private func agentRecord(
    kind: UInt64,
    plaintext: String,
    tags: [MessageTagFfi]
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("aa"),
        direction: "received",
        groupIdHex: hex("bb"),
        sender: hex("11"),
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: kind,
        tags: tags,
        recordedAt: 1,
        receivedAt: 1
    )
}

private func timelineRecord(
    messageIdHex: String,
    sender: String,
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi],
    timelineAt: UInt64
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: "received",
        groupIdHex: hex("bb"),
        sender: sender,
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: timelineAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: nil,
        media: [],
        agentTextStreamJson: nil,
        groupSystem: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func testAgentGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: hex("bb"),
        endpoint: "",
        name: "Hermes",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: MessageSemantics.encryptedMediaVersion,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// `MessagePreview.body(_ record:)` and `MessagePreview.isPreviewable(_:)` must
/// agree on which records carry displayable text. A reaction's emoji, a delete
/// tombstone, or a kind-1200 stream-start signal must never surface as message
/// body — that is the divergence these tests pin (see issue #367).
struct MessagePreviewBodyTests {
    @Test func reactionRecordHasNoBodyAndIsNotPreviewable() {
        let record = previewRecord(
            kind: MessageSemantics.kindReaction,
            plaintext: "👍",
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, hex("cc")])]
        )

        #expect(MessageSemantics.classify(record) == .reaction(targetMessageId: hex("cc")))
        #expect(MessagePreview.isPreviewable(record) == false)
        #expect(MessagePreview.body(record) == "")
    }

    @Test func deleteRecordHasNoBodyAndIsNotPreviewable() {
        let record = previewRecord(
            kind: MessageSemantics.kindDelete,
            plaintext: "tombstone-should-not-render",
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, hex("cc")])]
        )

        #expect(MessageSemantics.classify(record) == .delete(targetMessageId: hex("cc")))
        #expect(MessagePreview.isPreviewable(record) == false)
        #expect(MessagePreview.body(record) == "")
    }

    @Test func agentStreamStartRecordHasNoBodyAndIsNotPreviewable() {
        // A valid stream-start needs a 32-byte (64-char) hex stream id plus the
        // text/quic/final-kind tags; otherwise it would degrade to .unknown.
        let streamId = String(repeating: "ab", count: 32)
        let record = previewRecord(
            kind: MessageSemantics.kindAgentStreamStart,
            plaintext: "kind-1200-signal-should-not-render",
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamTypeTag, MessageSemantics.streamTypeText]),
                MessageTagFfi(values: [MessageSemantics.streamFinalKindTag, MessageSemantics.streamFinalKindChat]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, MessageSemantics.streamRouteQuic]),
            ]
        )

        guard case .agentStreamStart = MessageSemantics.classify(record) else {
            Issue.record("Expected the record to classify as .agentStreamStart")
            return
        }
        #expect(MessagePreview.isPreviewable(record) == false)
        #expect(MessagePreview.body(record) == "")
    }

    @Test func unknownRecordHasNoBodyAndIsNotPreviewable() {
        let record = previewRecord(
            kind: 9999,
            plaintext: "opaque-payload-should-not-render",
            tags: []
        )

        #expect(MessageSemantics.classify(record) == .unknown)
        #expect(MessagePreview.isPreviewable(record) == false)
        #expect(MessagePreview.body(record) == "")
    }

    @Test func plainChatRecordStillReturnsItsPlaintextBody() {
        // Positive control: the split must not regress real chat previews.
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: "hello world",
            tags: []
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record) == true)
        #expect(MessagePreview.body(record) == "hello world")
    }
}

private func previewRecord(
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

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

import Foundation
import Testing
@testable import whitenoise_ios
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

    @Test func remoteGiphyMessageUsesAStableNonTrackingPreviewLabel() {
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: "https://media1.giphy.com/media/abc/giphy.mp4?cid=client&rid=giphy.mp4\nvia GIPHY · Creator",
            tags: []
        )

        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "GIF via GIPHY")
    }

    /// A GIF sharing its message with photos classifies as media, whose preview
    /// branch flattens plaintext — which here is the envelope, not a caption.
    @Test func mediaClassifiedGiphyMessagePreviewsItsCaptionNotTheEnvelope() throws {
        let media = RemoteGiphyMedia(
            url: try #require(URL(string: "https://media.giphy.com/media/abc/giphy.gif")),
            width: 480,
            height: 270,
            attribution: "Marmot Studio"
        )
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: try #require(media.captionedWireText("both of these")),
            tags: [encryptedMediaTag()]
        )

        let preview = MessagePreview.body(record)

        #expect(preview == "both of these")
        #expect(!preview.contains("giphy.com"))
    }

    @Test func tokenlessEditedBodyRendersCanonicalMentionAsDisplayName() throws {
        // MDK emits empty markdown tokens for kind-1009 edits. Once projected
        // onto the original chat row, the body must still render the mention.
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: "updated @\(npub)",
            tags: []
        )

        let body = MessagePreview.body(record) { entity in
            entity.bech32 == npub ? "Alex" : nil
        }
        #expect(body == "updated @Alex")
    }

    @Test func tokenlessEditedMediaCaptionRendersCanonicalMentionAsDisplayName() throws {
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: "updated @\(npub)",
            tags: [encryptedMediaTag()]
        )

        guard case .media = MessageSemantics.classify(record) else {
            Issue.record("Expected a media record")
            return
        }
        let body = MessageBubble.bodyText(
            for: record,
            hasMediaItems: true,
            mentionDisplayName: { entity in
                entity.bech32 == npub ? "Alex" : nil
            }
        )
        #expect(body == "updated @Alex")
    }

    @Test func mediaBubbleWithEmptyCaptionDoesNotRenderAttachmentFallback() {
        let record = previewRecord(
            kind: MessageSemantics.kindChat,
            plaintext: "",
            tags: [encryptedMediaTag()]
        )

        guard case .media = MessageSemantics.classify(record) else {
            Issue.record("Expected a media record")
            return
        }
        #expect(MessageBubble.bodyText(for: record, hasMediaItems: true) == "")
    }

    @Test func timelineReplyMediaFallbackCapsPeerControlledFileNames() {
        let imeta = (0..<(MessagePreview.timelineMediaPreviewMaxFileNames + 3)).map {
            [MessageSemantics.imetaTag, "filename file\($0).png"]
        }
        let preview = timelineReplyPreview(mediaJson: mediaPreviewJson(imeta: imeta))

        #expect(MessagePreview.body(preview) == "📎 \(MessagePreview.timelineMediaPreviewMaxFileNames) attachments")
    }

    @Test func timelineReplyMediaFallbackPreservesNormalAttachmentCeilingCount() {
        let imeta = (0..<MediaDraftProcessor.maxAttachmentCount).map {
            [MessageSemantics.imetaTag, "filename file\($0).png"]
        }
        let preview = timelineReplyPreview(mediaJson: mediaPreviewJson(imeta: imeta))

        #expect(MessagePreview.body(preview) == "📎 \(MediaDraftProcessor.maxAttachmentCount) attachments")
    }

    @Test func timelineReplyMediaFallbackDoesNotInspectTagsPastBudget() {
        let emptyTags = Array(
            repeating: [MessageSemantics.imetaTag],
            count: MessagePreview.timelineMediaPreviewMaxTags
        )
        let preview = timelineReplyPreview(
            mediaJson: mediaPreviewJson(imeta: emptyTags + [[MessageSemantics.imetaTag, "filename late.png"]])
        )

        #expect(MessagePreview.body(preview) == "📎 Attachment")
    }

    @Test func timelineReplyMediaFallbackDoesNotInspectFieldsPastBudget() {
        let ignoredFields = Array(
            repeating: "field ignored",
            count: MessagePreview.timelineMediaPreviewMaxFieldsPerTag
        )
        let preview = timelineReplyPreview(
            mediaJson: mediaPreviewJson(
                imeta: [[MessageSemantics.imetaTag] + ignoredFields + ["filename late.png"]]
            )
        )

        #expect(MessagePreview.body(preview) == "📎 Attachment")
    }

    @Test func timelineReplyMediaFallbackRejectsOversizedMediaJson() {
        let oversizedJson = "{\"imeta\":[],\"padding\":\"" +
            String(repeating: "x", count: MessagePreview.timelineMediaPreviewMaxJsonBytes) +
            "\"}"
        let preview = timelineReplyPreview(mediaJson: oversizedJson)

        #expect(MessagePreview.body(preview) == "📎 Attachment")
    }
}

private func timelineReplyPreview(mediaJson: String) -> TimelineReplyPreviewFfi {
    TimelineReplyPreviewFfi(
        messageIdHex: hex("dd"),
        sender: hex("11"),
        plaintext: "",
        kind: MessageSemantics.kindChat,
        mediaJson: mediaJson,
        agentTextStreamJson: nil,
        deleted: false
    )
}

private func mediaPreviewJson(imeta: [[String]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["imeta": imeta])
    return String(data: data, encoding: .utf8)!
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

private func encryptedMediaTag() -> MessageTagFfi {
    MessageTagFfi(values: [
        MessageSemantics.imetaTag,
        "v \(EncryptedMediaVersionFfi.v1.wireValue)",
        "locator blossom-v1 https://media.example/\(hex("44")).bin",
        "ciphertext_sha256 \(hex("44"))",
        "plaintext_sha256 \(hex("33"))",
        "nonce \(String(repeating: "22", count: 12))",
        "m image/jpeg",
        "filename a.jpg",
    ])
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}

import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

struct ConversationTranscriptExportTests {
    @Test func documentEncodesInnerEventFieldsInTimelineOrder() throws {
        let groupId = String(repeating: "aa", count: 32)
        let firstId = String(repeating: "11", count: 32)
        let secondId = String(repeating: "22", count: 32)
        let records = [
            timelineRecord(
                messageIdHex: secondId,
                plaintext: "final answer",
                kind: MessageSemantics.kindChat,
                tags: [
                    MessageTagFfi(values: [MessageSemantics.streamTag, String(repeating: "ab", count: 32)]),
                ],
                timelineAt: 2,
                agentTextStreamJson: #"{"stream_id_hex":"bbbb","status":"finalized"}"#
            ),
            timelineRecord(
                messageIdHex: firstId,
                plaintext: "",
                kind: MessageSemantics.kindAgentStreamStart,
                tags: [
                    MessageTagFfi(values: [MessageSemantics.streamTag, String(repeating: "ab", count: 32)]),
                    MessageTagFfi(values: ["stream-type", "text"]),
                ],
                timelineAt: 1,
                agentTextStreamJson: #"{"stream_id_hex":"bbbb","status":"started"}"#
            ),
        ]

        let document = ConversationTranscriptExport.makeDocument(
            group: testExportGroup(name: "Hermes 2", groupIdHex: groupId),
            messages: records,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(document.eventCount == 2)
        #expect(document.events[0].messageIdHex == firstId)
        #expect(document.events[0].kind == MessageSemantics.kindAgentStreamStart)
        #expect(document.events[1].messageIdHex == secondId)
        #expect(document.events[1].kind == MessageSemantics.kindChat)
        #expect(document.events[1].content == "final answer")
        #expect(document.events[1].tags.first?.first == MessageSemantics.streamTag)

        let data = try ConversationTranscriptExport.encodeJSON(document)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["group_name"] as? String == "Hermes 2")
        #expect((json["events"] as? [[String: Any]])?.count == 2)
    }

    @Test func sortChronologicallyOrdersTiedTimestampsByMessageId() {
        let earlierId = String(repeating: "11", count: 32)
        let laterId = String(repeating: "22", count: 32)
        let records = [
            timelineRecord(messageIdHex: laterId, timelineAt: 5),
            timelineRecord(messageIdHex: earlierId, timelineAt: 5),
            timelineRecord(messageIdHex: String(repeating: "33", count: 32), timelineAt: 4),
        ]

        let document = ConversationTranscriptExport.makeDocument(
            group: testExportGroup(name: "Test"),
            messages: records
        )

        #expect(document.events.map(\.messageIdHex) == [
            String(repeating: "33", count: 32),
            earlierId,
            laterId,
        ])
    }

    @Test func temporaryFileWriteUsesCompleteFileProtection() throws {
        let data = Data("private transcript".utf8)
        let url = try ConversationTranscriptExport.writeTemporaryFile(
            data: data,
            groupIdHex: String(repeating: "ab", count: 32),
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try Data(contentsOf: url) == data)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("darkmatter-ios/Core/ConversationTranscriptExport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains(".protectionKey: FileProtectionType.complete"))
        #expect(source.contains("data.write(to: url, options: [.atomic, .completeFileProtection])"))
        #expect(source.contains("setAttributes(protectedAttributes, ofItemAtPath: url.path)"))
    }
}

private func testExportGroup(
    name: String,
    groupIdHex: String = String(repeating: "aa", count: 32)
) -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: groupIdHex,
        endpoint: "",
        name: name,
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: String(repeating: "bb", count: 32),
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

private func timelineRecord(
    messageIdHex: String,
    direction: String = "received",
    sender: String = String(repeating: "99", count: 32),
    plaintext: String = "hello",
    kind: UInt64 = MessageSemantics.kindChat,
    tags: [MessageTagFfi] = [],
    timelineAt: UInt64,
    agentTextStreamJson: String? = nil
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: direction,
        groupIdHex: String(repeating: "aa", count: 32),
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
        agentTextStreamJson: agentTextStreamJson,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

import Foundation
import Testing
@testable import whitenoise_ios
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

    @Test func documentSanitizesGroupNameBeforeExporting() throws {
        let groupId = String(repeating: "ab", count: 32)
        let document = ConversationTranscriptExport.makeDocument(
            group: testExportGroup(
                name: "\u{202E}  Secret\n\tRoom \u{200B}",
                groupIdHex: groupId
            ),
            messages: []
        )

        #expect(document.groupName == "Secret Room")

        let data = try ConversationTranscriptExport.encodeJSON(document)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["group_name"] as? String == "Secret Room")
    }

    @Test func documentFallsBackToShortGroupIdWhenGroupNameSanitizesEmpty() {
        let groupId = String(repeating: "ab", count: 32)
        let document = ConversationTranscriptExport.makeDocument(
            group: testExportGroup(name: "\u{202E}\u{200B}\n\t", groupIdHex: groupId),
            messages: []
        )

        #expect(document.groupName == IdentityFormatter.short(groupId))
    }

    @Test func fetchAllMessagesPaginatesByOldestMessageAndSortsChronologically() throws {
        let newestId = String(repeating: "33", count: 32)
        let middleId = String(repeating: "22", count: 32)
        let oldestId = String(repeating: "11", count: 32)
        let groupId = String(repeating: "aa", count: 32)
        let reader = FakeTranscriptTimelineReader(pages: [
            TimelinePageFfi(
                messages: [
                    timelineRecord(messageIdHex: newestId, timelineAt: 3),
                    timelineRecord(messageIdHex: middleId, timelineAt: 2),
                ],
                hasMoreBefore: true,
                hasMoreAfter: false
            ),
            TimelinePageFfi(
                messages: [timelineRecord(messageIdHex: oldestId, timelineAt: 1)],
                hasMoreBefore: false,
                hasMoreAfter: false
            ),
        ])

        let messages = try ConversationTranscriptExport.fetchAllMessages(
            timelineReader: reader,
            accountRef: "account-1",
            groupIdHex: groupId
        )

        #expect(messages.map(\.messageIdHex) == [oldestId, middleId, newestId])
        #expect(reader.accountRefs == ["account-1", "account-1"])
        #expect(reader.queries.count == 2)
        let firstQuery = try #require(reader.queries.first)
        #expect(firstQuery.groupIdHex == groupId)
        #expect(firstQuery.before == nil)
        #expect(firstQuery.beforeMessageId == nil)
        #expect(firstQuery.limit == ConversationTranscriptExport.pageLimit)
        let secondQuery = try #require(reader.queries.last)
        #expect(secondQuery.before == 2)
        #expect(secondQuery.beforeMessageId == middleId)
        #expect(secondQuery.limit == ConversationTranscriptExport.pageLimit)
    }

    @Test func fetchAllMessagesStopsBeforeAppendingRepeatedPageWhenCursorStalls() throws {
        let newestId = String(repeating: "44", count: 32)
        let oldestId = String(repeating: "22", count: 32)
        let groupId = String(repeating: "aa", count: 32)
        let page = TimelinePageFfi(
            messages: [
                timelineRecord(messageIdHex: newestId, timelineAt: 4),
                timelineRecord(messageIdHex: oldestId, timelineAt: 2),
            ],
            hasMoreBefore: true,
            hasMoreAfter: false
        )
        let reader = RepeatingTranscriptTimelineReader(page: page, maximumReads: 2)

        let messages = try ConversationTranscriptExport.fetchAllMessages(
            timelineReader: reader,
            accountRef: "account-1",
            groupIdHex: groupId
        )

        #expect(messages.map(\.messageIdHex) == [oldestId, newestId])
        #expect(reader.queries.count == 2)
        #expect(reader.queries[0].before == nil)
        #expect(reader.queries[0].beforeMessageId == nil)
        #expect(reader.queries[1].before == 2)
        #expect(reader.queries[1].beforeMessageId == oldestId)
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
        media: [],
        agentTextStreamJson: agentTextStreamJson,
        groupSystem: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private final class FakeTranscriptTimelineReader: ConversationTranscriptTimelineReading {
    private var pages: [TimelinePageFfi]
    private(set) var accountRefs: [String] = []
    private(set) var queries: [TimelineMessageQueryFfi] = []

    init(pages: [TimelinePageFfi]) {
        self.pages = pages
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        accountRefs.append(accountRef)
        queries.append(query)
        return pages.removeFirst()
    }
}

private enum RepeatingTranscriptTimelineReaderError: Error {
    case exceededMaximumReads
}

private final class RepeatingTranscriptTimelineReader: ConversationTranscriptTimelineReading {
    private let page: TimelinePageFfi
    private let maximumReads: Int
    private(set) var queries: [TimelineMessageQueryFfi] = []

    init(page: TimelinePageFfi, maximumReads: Int) {
        self.page = page
        self.maximumReads = maximumReads
    }

    func timelineMessages(accountRef: String, query: TimelineMessageQueryFfi) throws -> TimelinePageFfi {
        queries.append(query)
        if queries.count > maximumReads {
            throw RepeatingTranscriptTimelineReaderError.exceededMaximumReads
        }
        return page
    }
}

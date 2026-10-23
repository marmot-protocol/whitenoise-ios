import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct MessageSemanticsTests {

    @Test func decodedUnsignedEventChatPreviewsItsContent() {
        let record = unsignedEventRecord(
            plaintext: "hello from the inner content",
            kind: MessageSemantics.kindChat,
            tags: []
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "hello from the inner content")
    }

    @Test func decodedUnsignedEventControlsDoNotPreviewAsText() {
        let target = hex("44")
        let streamId = hex("ab")
        let reaction = unsignedEventRecord(
            plaintext: "+",
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])]
        )
        let deletion = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindDelete,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])]
        )
        let streamStart = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindAgentStreamStart,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: ["stream-type", "text"]),
                MessageTagFfi(values: ["final-kind", "9"]),
                MessageTagFfi(values: [MessageSemantics.streamRouteTag, "quic"]),
            ]
        )
        let agentActivity = unsignedEventRecord(
            plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
            kind: MessageSemantics.kindAgentActivity,
            tags: [MessageTagFfi(values: ["status", "thinking"])]
        )
        let agentOperation = unsignedEventRecord(
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            tags: [MessageTagFfi(values: ["operation", "tool_call"])]
        )
        let groupSystem = unsignedEventRecord(
            plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
            kind: MessageSemantics.kindGroupSystem,
            tags: [MessageTagFfi(values: ["system", "member_added"])]
        )

        #expect(MessageSemantics.classify(reaction) == .reaction(targetMessageId: target))
        #expect(MessageSemantics.classify(deletion) == .delete(targetMessageId: target))
        #expect(MessageSemantics.classify(agentActivity) == .agentActivity)
        #expect(MessageSemantics.classify(agentOperation) == .agentOperation)
        #expect(MessageSemantics.classify(groupSystem) == .groupSystem)
        #expect(!MessagePreview.isPreviewable(reaction))
        #expect(!MessagePreview.isPreviewable(deletion))
        #expect(!MessagePreview.isPreviewable(streamStart))
        #expect(!MessagePreview.isPreviewable(agentActivity))
        #expect(!MessagePreview.isPreviewable(agentOperation))
        #expect(!MessagePreview.isPreviewable(groupSystem))
        #expect(MessagePreview.body(agentActivity) == "Thinking")
        #expect(MessagePreview.body(agentOperation) == "Searching")
        #expect(MessagePreview.body(groupSystem) == "Member added")
    }

    @Test func typedAgentReplyPreviewDoesNotExposeRawJson() {
        let preview = TimelineReplyPreviewFfi(
            messageIdHex: hex("bb"),
            sender: hex("11"),
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            mediaJson: nil,
            media: [],
            agentTextStreamJson: nil,
            deleted: false
        )

        #expect(MessagePreview.body(preview) == "Searching")
    }

    @Test func decodedUnsignedEventStreamFinalPreviewsTranscript() {
        let streamId = hex("ab")
        let record = unsignedEventRecord(
            plaintext: "complete answer",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, streamId]),
                MessageTagFfi(values: [MessageSemantics.streamStartTag, hex("cc")]),
                MessageTagFfi(values: [MessageSemantics.streamHashTag, hex("55")]),
                MessageTagFfi(values: [MessageSemantics.streamChunksTag, "2"]),
            ]
        )

        #expect(MessageSemantics.classify(record) == .streamFinal(streamId: streamId))
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "complete answer")
    }

    @Test func incompleteStreamFinalIsPlainChatNotAStreamFinal() {
        let record = unsignedEventRecord(
            plaintext: "complete answer",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [MessageSemantics.streamTag, hex("ab")]),
                MessageTagFfi(values: [MessageSemantics.streamHashTag, hex("55")]),
                MessageTagFfi(values: [MessageSemantics.streamChunksTag, "2"]),
            ]
        )

        #expect(MessageSemantics.classify(record) == .chat)
    }

    @Test func mediaReferenceUsesMdkCanonicalV2MediaTypeValidation() {
        let base = [
            MessageSemantics.imetaTag,
            "v encrypted-media-v2",
            "locator blossom-v1 https://media.example/a.txt",
            "ciphertext_sha256 \(hex("44"))",
            "plaintext_sha256 \(hex("33"))",
            "nonce \(String(repeating: "22", count: 12))",
            "m text/plain",
            "filename a.txt",
        ]

        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: base)]
        )?.first?.mediaType == "text/plain")

        var noncanonical = base
        noncanonical[6] = "m Text/Plain"
        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: noncanonical)]
        ) == nil)
    }

    @Test func mediaReferenceParsesEncryptedMediaV1ImetaFields() {
        let nonce = String(repeating: "22", count: 12)
        let record = AppMessageRecordFfi(
            messageIdHex: hex("dd"),
            direction: "received",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "v encrypted-media-v1",
                    "locator blossom-v1 https://media.example/\(hex("44")).bin",
                    "ciphertext_sha256 \(hex("44"))",
                    "plaintext_sha256 \(hex("33"))",
                    "nonce \(nonce)",
                    "m image/png",
                    "filename a.png",
                    "dim 640x480",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false))
            return
        }

        #expect(info.count == 1)
        #expect(info[0].locators == [MediaLocatorFfi(kind: "blossom-v1", value: "https://media.example/\(hex("44")).bin")])
        #expect(info[0].mediaType == "image/png")
        #expect(info[0].fileName == "a.png")
        #expect(info[0].plaintextSha256 == hex("33"))
        #expect(info[0].ciphertextSha256 == hex("44"))
        #expect(info[0].nonceHex == nonce)
        #expect(info[0].version == .v1)
        #expect(info[0].dim == "640x480")
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func mediaReferenceParsesMultipleEncryptedMediaAttachmentsInOrder() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "first.jpg", plaintextByte: "31", ciphertextByte: "41", nonce: nonce),
                encryptedMediaTag(fileName: "second.jpg", plaintextByte: "32", ciphertextByte: "42", nonce: nonce),
            ]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false))
            return
        }

        #expect(info.map(\.fileName) == ["first.jpg", "second.jpg"])
        #expect(MessagePreview.body(record) == "📎 2 attachments")
    }

    @Test func malformedMediaReferenceFallsBackToChat() {
        let record = AppMessageRecordFfi(
            messageIdHex: hex("dd"),
            direction: "received",
            groupIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "v encrypted-media-v1",
                    "locator blossom-v1 https://media.example/a.png",
                    "ciphertext_sha256 \(hex("44"))",
                    "plaintext_sha256 \(hex("33"))",
                    "m image/png",
                    "filename a.png",
                ])
            ],
            recordedAt: 1,
            receivedAt: 1
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func mediaReferenceRejectsLegacyMip04FieldsWithoutHidingMessage() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [
                MessageTagFfi(values: [
                    MessageSemantics.imetaTag,
                    "url https://media.example/a.png",
                    "m image/png",
                    "filename a.png",
                    "x \(hex("33"))",
                    "n \(nonce)",
                    "v mip04-v2",
                    "size 7",
                ])
            ]
        )

        #expect(MessageSemantics.classify(record) == .chat)
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func unsupportedBlurhashFieldIsRejectedByMdkWithoutHidingMessage() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        #expect(MessageSemantics.classify(record) == .chat)
    }

    @Test func validThumbhashIsPreserved() throws {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("thumbhash Abc123+/=_-")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }

        #expect(info[0].thumbhash == "Abc123+/=_-")
    }

    @Test func invalidThumbhashIsDroppedWithoutHidingAttachment() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag.values.append("thumbhash \(String(repeating: "x", count: 129))")
        let record = unsignedEventRecord(
            plaintext: "caption",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }
        #expect(info.count == 1)
        #expect(info[0].fileName == "a.png")
        #expect(info[0].thumbhash == nil)
        #expect(MessagePreview.body(record) == "caption")
    }

    @Test func invalidOptionalDimIsDroppedWithoutHidingAttachment() {
        var tag = encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44")
        tag = MessageTagFfi(values: tag.values.filter { !$0.hasPrefix("dim ") })
        tag.values.append("dim 640")
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [tag]
        )

        guard case .media(let info) = MessageSemantics.classify(record) else {
            #expect(Bool(false), "expected media")
            return
        }
        #expect(info.count == 1)
        #expect(info[0].dim == nil)
    }

    @Test func mediaReferenceWithoutCaptionFallsBackToFileName() {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44", nonce: nonce)
            ]
        )

        #expect(MessagePreview.body(record) == "📎 a.png")
    }

    @MainActor
    @Test func timelineMediaItemsUseCachedReferenceProjection() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let firstReference = encryptedMediaReference(
            fileName: "first.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let secondReference = encryptedMediaReference(
            fileName: "second.jpg",
            plaintextByte: "32",
            ciphertextByte: "42",
            sourceEpoch: 42
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        // Row-resolved references arrive already ordered (Marmot preserves imeta order).
        viewModel.replaceMediaReferencesForTesting([firstReference, secondReference], forMessageId: messageId)

        let firstRead = viewModel.mediaItems(for: item)
        let buildCountAfterProjection = viewModel.mediaItemProjectionBuildCountForTesting
        let secondRead = viewModel.mediaItems(for: item)

        #expect(firstRead.map(\.fileName) == ["first.jpg", "second.jpg"])
        #expect(secondRead == firstRead)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterProjection)
    }

    @MainActor
    @Test func mediaReferenceUpdateRefreshesOnlyChangedTimelineProjection() throws {
        let messageId = hex("dd")
        let otherMessageId = hex("ee")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let otherRecord = timelineRecord(messageIdHex: otherMessageId, timelineAt: 2)
        let firstReference = encryptedMediaReference(fileName: "first.jpg", plaintextByte: "31", ciphertextByte: "41", sourceEpoch: 42)
        let replacementReference = encryptedMediaReference(fileName: "replacement.jpg", plaintextByte: "32", ciphertextByte: "42", sourceEpoch: 42)
        let otherReference = encryptedMediaReference(fileName: "other.jpg", plaintextByte: "33", ciphertextByte: "43", sourceEpoch: 42)

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record, otherRecord], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first { $0.id == "msg:\(messageId)" })
        let otherItem = try #require(viewModel.timeline.first { $0.id == "msg:\(otherMessageId)" })
        viewModel.replaceMediaReferencesForTesting([firstReference], forMessageId: messageId)
        viewModel.replaceMediaReferencesForTesting([otherReference], forMessageId: otherMessageId)
        let buildCountAfterInitialProjection = viewModel.mediaItemProjectionBuildCountForTesting

        #expect(viewModel.replaceMediaReferencesForTesting([replacementReference], forMessageId: messageId))
        let updated = viewModel.mediaItems(for: item)
        let unchanged = viewModel.mediaItems(for: otherItem)

        #expect(updated.map(\.fileName) == ["replacement.jpg"])
        #expect(unchanged.map(\.fileName) == ["other.jpg"])
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterInitialProjection + 1)
    }

    @MainActor
    @Test func timelineMediaItemsDoNotClassifyTagsWhenRowProjectionIsEmpty() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(
            messageIdHex: messageId,
            plaintext: "caption",
            tags: [encryptedMediaTag(fileName: "classified.jpg", plaintextByte: "31", ciphertextByte: "41")],
            timelineAt: 1
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        let buildCountAfterProjection = viewModel.mediaItemProjectionBuildCountForTesting

        let firstRead = viewModel.mediaItems(for: item)
        let secondRead = viewModel.mediaItems(for: item)

        #expect(firstRead.isEmpty)
        #expect(secondRead.isEmpty)
        #expect(viewModel.mediaItemProjectionBuildCountForTesting == buildCountAfterProjection)
    }

    @MainActor
    @Test func pendingMediaOverridesCachedTimelineProjection() throws {
        let messageId = hex("dd")
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "", id: hex("aa"))
        )
        let record = timelineRecord(messageIdHex: messageId, timelineAt: 1)
        let listedReference = encryptedMediaReference(
            fileName: "listed.jpg",
            plaintextByte: "31",
            ciphertextByte: "41",
            sourceEpoch: 42
        )
        let pending = MessageMediaAttachment(
            id: "pending-local",
            reference: nil,
            fileName: "pending.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )
        let item = try #require(viewModel.timeline.first)
        viewModel.replaceMediaReferencesForTesting([listedReference], forMessageId: messageId)
        #expect(viewModel.mediaItems(for: item).map(\.fileName) == ["listed.jpg"])

        viewModel.installPendingMediaForTesting(rowId: item.id, items: [pending])
        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [record], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.mediaItems(for: item) == [pending])
    }

    @Test func mediaDownloadInFlightKeyNormalizesCryptoIdentity() {
        var uppercase = encryptedMediaReference(sourceEpoch: 0)
        let lowercase = uppercase
        uppercase.plaintextSha256 = uppercase.plaintextSha256.uppercased()
        uppercase.ciphertextSha256 = uppercase.ciphertextSha256.uppercased()
        uppercase.nonceHex = uppercase.nonceHex.uppercased()

        #expect(MediaDownloadInFlightKey(reference: uppercase) == MediaDownloadInFlightKey(reference: lowercase))
    }

    @MainActor
    @Test func inFlightMediaDownloadsShareTaskForSameReference() async throws {
        let store = MediaDownloadInFlightStore()
        let key = MediaDownloadInFlightKey(reference: encryptedMediaReference(sourceEpoch: 0))
        let probe = MediaDownloadProbe()

        async let first = store.data(for: key) {
            await probe.run(returning: Data([1]))
        }
        async let second = store.data(for: key) {
            await probe.run(returning: Data([2]))
        }

        let results = try await (first, second)
        #expect(results.0 == results.1)
        #expect(await probe.startCount() == 1)
    }

    @MainActor
    @Test func inFlightMediaDownloadsClearCompletedTask() async throws {
        let store = MediaDownloadInFlightStore()
        let key = MediaDownloadInFlightKey(reference: encryptedMediaReference(sourceEpoch: 0))
        var starts = 0

        let first = try await store.data(for: key) {
            starts += 1
            return Data([UInt8(starts)])
        }
        let second = try await store.data(for: key) {
            starts += 1
            return Data([UInt8(starts)])
        }

        #expect(first == Data([1]))
        #expect(second == Data([2]))
        #expect(starts == 2)
    }

    @Test func mediaAttachmentIdentityChangesWhenSourceEpochArrives() throws {
        let timelineReference = encryptedMediaReference(sourceEpoch: 0)
        let listedReference = encryptedMediaReference(sourceEpoch: 42)

        let timelineItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [timelineReference],
                ownerId: "msg-a"
            ).first
        )
        let listedItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [listedReference],
                ownerId: "msg-a"
            ).first
        )

        #expect(timelineItem.id != listedItem.id)
        #expect(timelineItem.id.hasSuffix(":0:0"))
        #expect(listedItem.id.hasSuffix(":42:0"))
    }

    @Test func mediaAttachmentIdentityIncludesOwningMessage() throws {
        let reference = encryptedMediaReference(sourceEpoch: 0)

        let firstItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [reference],
                ownerId: "msg-a"
            ).first
        )
        let secondItem = try #require(
            MessageMediaAttachment.displayItems(
                from: [reference],
                ownerId: "msg-b"
            ).first
        )

        #expect(firstItem.id != secondItem.id)
        #expect(firstItem.id.hasPrefix("msg-a:"))
        #expect(secondItem.id.hasPrefix("msg-b:"))
    }

    @Test func receivedMediaDisplayFileNameStripsSpoofingScalars() throws {
        let reference = encryptedMediaReference(
            fileName: "photo\u{202E}gpj.exe",
            plaintextByte: "46",
            ciphertextByte: "47",
            sourceEpoch: 0
        )

        let item = try #require(MessageMediaAttachment.displayItems(from: [reference], ownerId: "msg").first)

        #expect(item.fileName == "photogpj.exe")
        #expect(MessagePreview.mediaFallback([reference]) == "📎 photogpj.exe")
    }

    @Test func mediaCacheStoresPlaintextWithCompleteFileProtection() throws {
        let reference = encryptedMediaReference(
            plaintextByte: "7a",
            ciphertextByte: "7b",
            sourceEpoch: 0
        )
        let data = Data([0x01, 0x02, 0x03])
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(data, for: reference, cachesDirectory: cachesDirectory)

        #expect(try Data(contentsOf: url) == data)
    }

    @Test func mediaCacheURLIgnoresUnsafePeerFilenameExtension() throws {
        let reference = encryptedMediaReference(
            fileName: "folder/evil",
            plaintextByte: "7c",
            ciphertextByte: "7d",
            mediaType: "image/png",
            sourceEpoch: 0
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheUnsafeExtensionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        #expect(url.lastPathComponent == "\(reference.plaintextSha256).png")
        #expect(url.deletingLastPathComponent().lastPathComponent == "EncryptedMedia")
    }

    @Test func mediaCacheEvictsExpiredPlaintext() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheEvictionAgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let oldReference = encryptedMediaReference(
            plaintextByte: "10",
            ciphertextByte: "11",
            sourceEpoch: 0
        )
        let freshReference = encryptedMediaReference(
            plaintextByte: "12",
            ciphertextByte: "13",
            sourceEpoch: 0
        )
        let oldURL = try #require(MessageMediaCache.cacheURL(for: oldReference, cachesDirectory: cachesDirectory))
        let freshURL = try #require(MessageMediaCache.cacheURL(for: freshReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data([0x01]),
            for: oldReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_000)
        )
        MessageMediaCache.store(
            Data([0x02]),
            for: freshReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_061)
        )

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: freshURL.path))
    }

    @Test func mediaCacheEvictsLeastRecentlyUsedPlaintextBySize() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 8, maxAge: 60 * 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheEvictionSizeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let firstReference = encryptedMediaReference(
            plaintextByte: "20",
            ciphertextByte: "21",
            sourceEpoch: 0
        )
        let secondReference = encryptedMediaReference(
            plaintextByte: "22",
            ciphertextByte: "23",
            sourceEpoch: 0
        )
        let thirdReference = encryptedMediaReference(
            plaintextByte: "24",
            ciphertextByte: "25",
            sourceEpoch: 0
        )
        let firstURL = try #require(MessageMediaCache.cacheURL(for: firstReference, cachesDirectory: cachesDirectory))
        let secondURL = try #require(MessageMediaCache.cacheURL(for: secondReference, cachesDirectory: cachesDirectory))
        let thirdURL = try #require(MessageMediaCache.cacheURL(for: thirdReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data(repeating: 0x01, count: 4),
            for: firstReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_000)
        )
        MessageMediaCache.store(
            Data(repeating: 0x02, count: 4),
            for: secondReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_006)
        )
        MessageMediaCache.store(
            Data(repeating: 0x03, count: 4),
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 1_012)
        )

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))
    }

    @Test func mediaCacheThrottlesDirectoryWideSweeps() throws {
        let policy = DecryptedMediaCacheEvictionPolicy(maxBytes: 8, maxAge: 60 * 60)
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageMediaCacheSweepThrottleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let firstReference = encryptedMediaReference(
            plaintextByte: "26",
            ciphertextByte: "27",
            sourceEpoch: 0
        )
        let secondReference = encryptedMediaReference(
            plaintextByte: "28",
            ciphertextByte: "29",
            sourceEpoch: 0
        )
        let thirdReference = encryptedMediaReference(
            plaintextByte: "2a",
            ciphertextByte: "2b",
            sourceEpoch: 0
        )
        let firstURL = try #require(MessageMediaCache.cacheURL(for: firstReference, cachesDirectory: cachesDirectory))
        let secondURL = try #require(MessageMediaCache.cacheURL(for: secondReference, cachesDirectory: cachesDirectory))
        let thirdURL = try #require(MessageMediaCache.cacheURL(for: thirdReference, cachesDirectory: cachesDirectory))

        MessageMediaCache.store(
            Data(repeating: 0x01, count: 4),
            for: firstReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_000)
        )
        MessageMediaCache.store(
            Data(repeating: 0x02, count: 4),
            for: secondReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_001)
        )
        MessageMediaCache.store(
            Data(repeating: 0x03, count: 4),
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_002)
        )

        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))

        _ = MessageMediaCache.cachedData(
            for: thirdReference,
            cachesDirectory: cachesDirectory,
            policy: policy,
            now: Date(timeIntervalSince1970: 2_006)
        )

        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(FileManager.default.fileExists(atPath: thirdURL.path))
    }

    @Test func playbackStoreReusesContentAddressedMediaCacheForReferencedItems() throws {
        let reference = encryptedMediaReference(
            fileName: "clip.mp4",
            plaintextByte: "30",
            ciphertextByte: "31",
            mediaType: "video/mp4",
            sourceEpoch: 0
        )
        let item = MessageMediaAttachment(
            id: "message-a:\(reference.plaintextSha256):0:0",
            reference: reference,
            fileName: reference.fileName,
            mediaType: reference.mediaType,
            dim: nil,
            localData: nil
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPlaybackReuseTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }
        let expectedURL = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: cachesDirectory))

        let playbackURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x04, 0x05, 0x06]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_000)
            )
        )

        #expect(playbackURL == expectedURL)
        #expect(try Data(contentsOf: expectedURL) == Data([0x04, 0x05, 0x06]))
        #expect(!FileManager.default.fileExists(atPath: cachesDirectory.appendingPathComponent("EncryptedMediaPlayback").path))
    }

    @Test func playbackStoreUsesContentHashForUnreferencedItems() throws {
        let item = MessageMediaAttachment(
            id: "draft-reused-id",
            reference: nil,
            fileName: "clip.mp4",
            mediaType: "video/mp4",
            dim: nil,
            localData: nil
        )
        let cachesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPlaybackContentHashTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cachesDirectory) }

        let firstURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x01]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_000)
            )
        )
        let secondURL = try #require(
            MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x02]),
                cachesDirectory: cachesDirectory,
                mediaPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                playbackPolicy: DecryptedMediaCacheEvictionPolicy(maxBytes: 1_024, maxAge: 60),
                now: Date(timeIntervalSince1970: 1_001)
            )
        )

        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == Data([0x01]))
        #expect(try Data(contentsOf: secondURL) == Data([0x02]))
    }

    @MainActor
    @Test func conversationDisplayBodyUsesMediaFileNameFallback() throws {
        let nonce = String(repeating: "22", count: 12)
        let record = unsignedEventRecord(
            plaintext: "",
            kind: MessageSemantics.kindChat,
            tags: [
                encryptedMediaTag(fileName: "a.png", plaintextByte: "33", ciphertextByte: "44", nonce: nonce)
            ]
        )
        let viewModel = ConversationViewModel(
            appState: AppState.test(client: try MarmotClient.testClient()),
            group: group(name: "")
        )

        #expect(viewModel.displayBody(of: record) == "📎 a.png")
    }

    @Test func optimisticImetaParserRejectsUnsafeLocator() {
        let values = [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator blossom-v1 https://192.168.1.1/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]
        #expect(MessageSemantics.mediaAttachments(from: [MessageTagFfi(values: values)]) == nil)
    }

    @Test func optimisticImetaParserRetainsUnsupportedLocatorWithSafeBlossomFallback() throws {
        let values = [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator ipfs-v1 ipfs://bafy-test",
            "locator blossom-v1 https://media.example/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]

        let attachment = try #require(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: values)]
        )?.first)
        #expect(attachment.locators.map(\.kind) == ["ipfs-v1", "blossom-v1"])
    }

    @Test func optimisticImetaParserKeepsValidSiblingWhenMdkRejectsMalformedTag() throws {
        let valid = MessageTagFfi(values: [
            MessageSemantics.imetaTag,
            "v \(EncryptedMediaVersionFfi.v1.wireValue)",
            "locator blossom-v1 https://media.example/\(String(repeating: "a", count: 64)).bin",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ])
        let malformed = MessageTagFfi(values: [
            MessageSemantics.imetaTag,
            "v unknown-version",
        ])

        let attachment = try #require(MessageSemantics.mediaAttachments(
            from: [malformed, valid],
            sourceEpoch: 42
        )?.first)
        #expect(attachment.fileName == "photo.jpg")
        #expect(attachment.sourceEpoch == 42)
    }
}

private func encryptedMediaTag(
    fileName: String,
    plaintextByte: String,
    ciphertextByte: String,
    nonce: String = String(repeating: "22", count: 12),
    version: EncryptedMediaVersionFfi = .v1
) -> MessageTagFfi {
    MessageTagFfi(values: [
        MessageSemantics.imetaTag,
        "v \(version.wireValue)",
        "locator blossom-v1 https://media.example/\(hex(ciphertextByte)).bin",
        "ciphertext_sha256 \(hex(ciphertextByte))",
        "plaintext_sha256 \(hex(plaintextByte))",
        "nonce \(nonce)",
        "m image/jpeg",
        "filename \(fileName)",
        "dim 640x480",
    ])
}

private actor MediaDownloadProbe {
    private var starts = 0

    func run(returning data: Data) async -> Data {
        starts += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        return data
    }

    func startCount() -> Int {
        starts
    }
}

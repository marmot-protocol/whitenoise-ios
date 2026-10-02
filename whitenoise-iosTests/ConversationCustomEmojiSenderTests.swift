import CryptoKit
import Foundation
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct ConversationCustomEmojiSenderTests {
    typealias F = CustomEmojiFixtures

    struct SentMessage: Equatable {
        let scope: CustomEmojiScope
        let caption: String
        let attachments: [MediaAttachmentReferenceFfi]
        let tags: [[String]]
    }

    @MainActor final class Harness {
        var scope: CustomEmojiScope? = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g1")
        var epoch: UInt64? = 7
        var payloads: [String: Data] = [:]
        var loadError: Error?
        var uploadError: Error?
        var sendError: Error?
        var uploads: [MediaUploadAttachmentRequestFfi] = []
        var messages: [SentMessage] = []
        var beforeUploadReturns: (() -> Void)?
        var uploadGate: CheckedContinuation<Void, Never>?
        var holdsUpload = false

        lazy var sender = ConversationCustomEmojiSender(
            scopeProvider: { [weak self] in self?.scope },
            currentEpoch: { [weak self] in self?.epoch },
            loadBytes: { [weak self] item in
                guard let self else { throw CancellationError() }
                if let loadError { throw loadError }
                return self.payloads[item.reference?.plaintextSha256 ?? ""] ?? Data()
            },
            upload: { [weak self] _, request in
                guard let self else { throw CancellationError() }
                self.uploads.append(request)
                let serial = self.uploads.count
                let epochAtUpload = self.epoch ?? 0
                if self.holdsUpload {
                    await withCheckedContinuation { self.uploadGate = $0 }
                }
                self.beforeUploadReturns?()
                if let uploadError { throw uploadError }
                return Self.uploadedReference(for: request, epoch: epochAtUpload, serial: serial)
            },
            sendMessage: { [weak self] scope, caption, attachments, tags in
                guard let self else { throw CancellationError() }
                if let sendError { throw sendError }
                self.messages.append(SentMessage(scope: scope, caption: caption, attachments: attachments, tags: tags))
            }
        )

        static func uploadedReference(for request: MediaUploadAttachmentRequestFfi, epoch: UInt64, serial: Int) -> MediaAttachmentReferenceFfi {
            var reference = F.reference(url: "https://mine.example/\(serial)", sha: sha256(request.plaintext))
            reference.sourceEpoch = epoch
            return reference
        }

        func sendable(_ name: String, bytes: String) -> CustomEmojiSendable {
            let data = Data(bytes.utf8)
            let sha = sha256(data)
            payloads[sha] = data
            let received = F.reference(url: "https://theirs.example/\(name)", sha: sha)
            let source = F.attachments([.accepted(attachmentIndex: 0, reference: received)])[0]
            return CustomEmojiSendable(shortcode: CustomEmojiShortcode(name)!, reference: received, source: source)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Messages

    @Test func messageReEncryptsEachImageAndNamesTheUploadedLocator() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        let cat = harness.sendable("cat", bytes: "cat-png")
        try await harness.sender.sendMessage(text: ":cat: hi :party:", replyTargetId: "parent", emoji: [cat, party])

        #expect(harness.uploads.map(\.plaintext) == [Data("cat-png".utf8), Data("party-png".utf8)])
        #expect(harness.uploads.first?.fileName == cat.reference.fileName)
        let sent = try #require(harness.messages.first)
        #expect(sent.caption == ":cat: hi :party:")
        #expect(sent.scope.groupIdHex == "g1")
        #expect(sent.attachments.map(\.locators.first?.value) == ["https://mine.example/1", "https://mine.example/2"])
        #expect(sent.attachments.allSatisfy { $0.sourceEpoch == 7 })
        // Tags name the uploaded copy, never the received URL.
        #expect(sent.tags == [
            ["emoji", "cat", "https://mine.example/1"],
            ["emoji", "party", "https://mine.example/2"],
            ["e", "parent"],
            ["q", "parent"],
        ])
    }

    @Test func retryAfterASendFailureNeverUploadsAgain() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.sendError = MarmotKitError.Runtime(details: "relay down")
        await #expect(throws: CustomEmojiSendError.sendFailed) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        #expect(harness.uploads.count == 1)
        #expect(harness.messages.isEmpty)

        harness.sendError = nil
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 1)
        #expect(harness.sender.uploads.uploadCount == 1)
        #expect(harness.messages.count == 1)

        // A later message reuses the same uploaded reference.
        try await harness.sender.sendMessage(text: "again :party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 1)
        #expect(harness.messages[1].attachments == harness.messages[0].attachments)
    }

    @Test func failedUploadIsRetriedBecauseNoReferenceExistsYet() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.uploadError = MarmotKitError.Runtime(details: "blossom down")
        await #expect(throws: CustomEmojiSendError.uploadFailed) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        harness.uploadError = nil
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 2)
        #expect(harness.messages.count == 1)
    }

    @Test func concurrentSendsShareOneUpload() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.holdsUpload = true
        let first = Task { try await harness.sender.sendMessage(text: "a :party:", replyTargetId: nil, emoji: [party]) }
        let second = Task { try await harness.sender.sendMessage(text: "b :party:", replyTargetId: nil, emoji: [party]) }
        while harness.uploadGate == nil { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }
        harness.uploadGate?.resume()
        _ = try await first.value
        _ = try await second.value
        #expect(harness.uploads.count == 1)
        #expect(harness.messages.count == 2)
    }

    @Test func aScopeChangeDuringUploadNeverSendsIntoAnotherConversation() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.beforeUploadReturns = {
            harness.scope = CustomEmojiScope(accountRef: "alice", runtimeGeneration: 1, groupIdHex: "g2")
        }
        await #expect(throws: CancellationError.self) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        #expect(harness.messages.isEmpty)

        // The late reference was not kept for the new chat either.
        harness.beforeUploadReturns = nil
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 2)
        #expect(harness.messages.first?.scope.groupIdHex == "g2")
    }

    @Test func accountSwitchDuringUploadDropsTheMessage() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.beforeUploadReturns = { harness.scope = nil }
        await #expect(throws: CancellationError.self) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        #expect(harness.messages.isEmpty)
    }

    @Test func anAdvancedEpochReEncryptsOnceForTheNewEpoch() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        harness.epoch = 8
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 2)
        #expect(harness.messages.map { $0.attachments.first?.sourceEpoch } == [7, 8, 8])
    }

    @Test func mdkStaleReferenceRefusalForcesOneFreshUpload() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.sendError = MarmotKitError.InvalidMediaReference(details: "media reference epoch 7 is stale")
        await #expect(throws: CustomEmojiSendError.staleEpoch) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        harness.sendError = nil
        try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        #expect(harness.uploads.count == 2)
    }

    @Test func unreadableOrMismatchedBytesFailWithoutUploading() async {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "party-png")
        harness.payloads[party.reference.plaintextSha256] = Data("tampered".utf8)
        await #expect(throws: CustomEmojiSendError.imageUnavailable) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        harness.loadError = MarmotKitError.Runtime(details: "blocked by policy")
        await #expect(throws: CustomEmojiSendError.imageUnavailable) {
            try await harness.sender.sendMessage(text: ":party:", replyTargetId: nil, emoji: [party])
        }
        #expect(harness.uploads.isEmpty)
    }

    @Test func overLimitMessagesFailBeforeAnyUpload() async {
        let harness = Harness()
        let emoji = (0..<63).map { harness.sendable("e\($0)", bytes: "png-\($0)") }
        await #expect(throws: CustomEmojiSendError.tooManyTags(count: 65)) {
            try await harness.sender.sendMessage(text: "lots", replyTargetId: "parent", emoji: emoji)
        }
        await #expect(throws: CustomEmojiSendError.emptyEventTarget) {
            try await harness.sender.sendMessage(text: ":e1:", replyTargetId: " ", emoji: [emoji[1]])
        }
        #expect(harness.uploads.isEmpty)
        #expect(harness.messages.isEmpty)
    }

    // MARK: Composer hand-off

    @MainActor final class SubmitterHarness {
        var sends = 0
        var events: [String] = []
        var sendError: Error?
        var draftGate: CheckedContinuation<Void, Never>?
        var holdsDraftCleanup = false

        lazy var submitter = CustomEmojiComposerSubmitter(
            send: { [weak self] _, _, _ in
                guard let self else { throw CancellationError() }
                self.sends += 1
                if let sendError { throw sendError }
                return []
            },
            completeDraft: { [weak self] _ in
                guard let self else { return }
                if self.holdsDraftCleanup {
                    await withCheckedContinuation { self.draftGate = $0 }
                }
                self.events.append("draft")
            },
            storeSentBytes: { [weak self] _, _ in self?.events.append("cache") },
            cacheGeneration: { 0 }
        )

        let submission = CustomEmojiSubmittedDraft(
            accountRef: "alice", groupIdHex: "g1", text: "yay :party:", replyTargetId: nil,
            draft: ConversationDraftSnapshot(canonicalText: "yay :party:", replyToMessageIdHex: nil, mediaAttachments: []))
    }

    @Test func sendStaysInFlightUntilDraftAndComposerCleanupFinish() async {
        let harness = SubmitterHarness()
        harness.holdsDraftCleanup = true
        let first = Task {
            await harness.submitter.submit(harness.submission, emoji: []) { harness.events.append("composer") }
        }
        while harness.draftGate == nil { await Task.yield() }

        // Accepted by MDK, cleanup pending: Send and attachments stay blocked.
        #expect(harness.submitter.isSending)
        #expect(!harness.submitter.state.admitsNewAttachments)
        let second = await harness.submitter.submit(harness.submission, emoji: []) { harness.events.append("second") }
        #expect(!second)
        #expect(harness.sends == 1)

        harness.draftGate?.resume()
        #expect(await first.value)
        // Optional cache writes come only after the composer was cleared.
        #expect(harness.events == ["draft", "composer", "cache"])
        #expect(!harness.submitter.isSending)
        #expect(harness.submitter.state.admitsNewAttachments)
    }

    @Test func failedSendKeepsTheDraftAndAllowsARetry() async {
        let harness = SubmitterHarness()
        harness.sendError = CustomEmojiSendError.uploadFailed
        #expect(!(await harness.submitter.submit(harness.submission, emoji: []) { harness.events.append("composer") }))
        #expect(harness.submitter.errorMessage == CustomEmojiSendError.uploadFailed.message)
        #expect(harness.events.isEmpty)

        harness.sendError = nil
        #expect(await harness.submitter.submit(harness.submission, emoji: []) { harness.events.append("composer") })
        #expect(harness.submitter.errorMessage == nil)
        #expect(harness.events == ["draft", "composer", "cache"])
    }
}

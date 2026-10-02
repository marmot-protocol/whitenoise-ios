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

    @Test func shortcodeAliasesOfOneImageSendOneAttachment() async throws {
        let harness = Harness()
        let party = harness.sendable("party", bytes: "same-png")
        let celebrate = harness.sendable("celebrate", bytes: "same-png")
        try await harness.sender.sendMessage(text: ":party: :celebrate:", replyTargetId: nil, emoji: [party, celebrate])
        #expect(harness.uploads.count == 1)
        let sent = try #require(harness.messages.first)
        #expect(sent.attachments.count == 1)
        #expect(sent.tags == [
            ["emoji", "party", "https://mine.example/1"],
            ["emoji", "celebrate", "https://mine.example/1"],
        ])
    }

    // MARK: Composer hand-off

    @MainActor final class SubmitterHarness {
        var sends = 0
        var events: [String] = []
        var sendError: Error?
        var claimed: UUID?
        var finishGate: CheckedContinuation<Void, Never>?
        var holdsFinish = false

        lazy var submitter = CustomEmojiComposerSubmitter(
            send: { [weak self] _, _, _ in
                guard let self else { throw CancellationError() }
                self.sends += 1
                if let sendError { throw sendError }
                return []
            },
            claim: { [weak self] _ in
                guard let self, self.claimed == nil else { return nil }
                let id = UUID()
                self.claimed = id
                return id
            },
            finish: { [weak self] claim, _, accepted in
                guard let self else { return }
                if self.holdsFinish {
                    await withCheckedContinuation { self.finishGate = $0 }
                }
                self.events.append(accepted ? "accepted" : "rejected")
                if self.claimed == claim { self.claimed = nil }
            },
            storeSentBytes: { [weak self] _, _ in self?.events.append("cache") },
            cacheGeneration: { 0 }
        )

        let submission = CustomEmojiSubmittedDraft(
            accountRef: "alice", groupIdHex: "g1", text: "yay :party:", replyTargetId: nil,
            draft: ConversationDraftSnapshot(canonicalText: "yay :party:", replyToMessageIdHex: nil, mediaAttachments: []))
    }

    @Test func claimIsHeldUntilDraftCleanupFinishesAndCacheWritesComeLast() async {
        let harness = SubmitterHarness()
        harness.holdsFinish = true
        let first = Task { await harness.submitter.submit(harness.submission, emoji: []) }
        while harness.finishGate == nil { await Task.yield() }

        // Accepted by MDK, cleanup pending: the claim still refuses a second send.
        #expect(harness.claimed != nil)
        #expect(!(await harness.submitter.submit(harness.submission, emoji: [])))
        #expect(harness.sends == 1)

        harness.finishGate?.resume()
        #expect(await first.value)
        #expect(harness.events == ["accepted", "cache"])
        #expect(harness.claimed == nil)
    }

    @Test func failedSendReleasesTheClaimKeepsTheErrorAndAllowsARetry() async {
        let harness = SubmitterHarness()
        harness.sendError = CustomEmojiSendError.uploadFailed
        #expect(!(await harness.submitter.submit(harness.submission, emoji: [])))
        #expect(harness.submitter.errorMessage == CustomEmojiSendError.uploadFailed.message)
        #expect(harness.events == ["rejected"])
        #expect(harness.claimed == nil)

        harness.sendError = nil
        #expect(await harness.submitter.submit(harness.submission, emoji: []))
        #expect(harness.submitter.errorMessage == nil)
        #expect(harness.events == ["rejected", "accepted", "cache"])
    }

    // MARK: Reconciling the composer on screen

    @Test func onlyAnUnchangedComposerClearsAfterAcceptance() {
        let parent = String(repeating: "ab", count: 32)
        let submitted = ConversationDraftSnapshot(canonicalText: "yay :party:", replyToMessageIdHex: parent, mediaAttachments: [])
        func clears(text: String = "yay :party: ", reply: String? = parent, media: Bool = false, editing: Bool = false) -> Bool {
            CustomEmojiComposerReconciliation.clears(submitted: submitted, canonicalText: text, replyTargetId: reply,
                                                     hasMediaDrafts: media, isEditing: editing)
        }
        #expect(clears())
        #expect(clears(reply: parent.uppercased()))
        #expect(!clears(text: "yay :party: more"))
        // A reply-only change during the upload keeps the composer.
        #expect(!clears(reply: nil))
        #expect(!clears(reply: String(repeating: "cd", count: 32)))
        #expect(!clears(media: true))
        #expect(!clears(editing: true))
    }

    @Test func everyConversationScreenForTheChatSeesTheInFlightSend() throws {
        let appState = AppState.test(client: try MarmotClient.testClient())
        appState.activeAccountRef = "account-1"
        let group = Self.group()
        let first = ConversationViewModel(appState: appState, group: group)
        let reopened = ConversationViewModel(appState: appState, group: group)
        #expect(!reopened.isSendingCustomEmojiMessage)
        let claim = appState.conversationDraftStore.beginUnrevisionedSend(
            ConversationDraftSnapshot(canonicalText: "yay :party:", replyToMessageIdHex: nil, mediaAttachments: []),
            accountRef: "account-1", groupIdHex: group.groupIdHex)
        #expect(claim != nil)
        // The screen opened after the send started also disables Send and
        // refuses attachments.
        #expect(first.isSendingCustomEmojiMessage)
        #expect(reopened.isSendingCustomEmojiMessage)
        #expect(!reopened.composerAdmitsNewAttachments)
        // Another account's screen for the same chat id is unaffected.
        appState.activeAccountRef = "account-2"
        #expect(!reopened.isSendingCustomEmojiMessage)
    }

    static func group() -> AppGroupRecordFfi {
        AppGroupRecordFfi(
            groupIdHex: String(repeating: "bb", count: 32), endpoint: "", name: "Emoji", description: "",
            admins: [], relays: [], nostrGroupIdHex: "", avatarUrl: nil, avatarDim: nil, avatarThumbhash: nil,
            encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                componentId: 0x8008, component: "marmot.group.encrypted-media.v1", required: true,
                mediaFormat: EncryptedMediaVersionFfi.v1.wireValue, allowedLocatorKinds: ["blossom-v1"],
                defaultBlobEndpoints: [AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")]),
            archived: false, pendingConfirmation: false, welcomerAccountIdHex: nil, viaWelcomeMessageIdHex: nil)
    }
}

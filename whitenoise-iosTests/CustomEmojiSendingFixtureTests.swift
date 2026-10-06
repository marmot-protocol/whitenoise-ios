import CryptoKit
import Foundation
import Network
import os
import Testing
import MarmotKit
@testable import whitenoise_ios

/// Binding fixture for sending MDK 0.12.0 custom emoji: a peer's emoji puts
/// `:party:` in the chat's catalog, then a tagged kind-9 goes through the
/// real `sendTaggedMedia` of a live test runtime and is read back through the
/// conversation window and the rendering resolver. The peer row is synthetic, so its retained bytes and
/// the Blossom upload are simulated; a local relay serves empty history and
/// refuses publication with a retryable response. The uploaded
/// reference is shaped like a real one for the group's epoch.
@MainActor
@Suite(.serialized)
struct CustomEmojiSendingFixtureTests {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func taggedMessageRoundTripsThroughTheRuntime() async throws {
        let relay = try CustomEmojiTestRelay()
        defer { relay.stop() }
        let relayURL = try await relay.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmojiSend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try MarmotClient(rootPath: root.path, relayUrls: [relayURL], cursorPersistence: .advance,
            telemetryConfig: .current(), relayPolicy: .allowLoopback)
        let watchdog = MarmotFixtureWatchdog.start("Custom emoji send fixture exceeded its deadline", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: [relayURL], bootstrapRelays: [relayURL]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Emoji send", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            func readSnapshot() async throws -> ConversationWindowSnapshotFfi {
                let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex)
                let snapshot = try #require(window.snapshot())
                await window.cancel()
                return snapshot
            }
            var snapshot = try await readSnapshot()
            let epoch = try await client.marmot.groupMlsState(accountRef: account.label, groupIdHex: group.groupIdHex).epoch
            let groupSubscription = try await client.subscribeGroupState(accountRef: account.label, groupIdHex: group.groupIdHex)
            let groupRecord = try #require(await client.groupStateSubscriptionSnapshot(groupSubscription))
            let state = AppState.test(client: client, accountDefaults: IsolatedAccountDefaults.make())
            state.activeAccountRef = account.label
            let model = ConversationViewModel(appState: state, group: groupRecord)

            // A peer's kind-9 with :party: gives this chat one sendable emoji.
            let payload = Data("party-emoji-png".utf8)
            let peerURL = "https://peer.example.com/party"
            var received = CustomEmojiFixtures.reference(url: peerURL, sha: Self.hex(payload))
            received.sourceEpoch = epoch
            let peer = String(repeating: "5e", count: 32)
            let peerMessageID = String(repeating: "9a", count: 32)
            var peerRow = TimelineMessageRecordFfi(messageIdHex: peerMessageID, sourceMessageIdHex: nil, direction: "received",
                groupIdHex: group.groupIdHex, sender: peer, plaintext: "look :party: :celebrate: :party-time:",
                contentTokens: .emptyDocument, kind: MessageSemantics.kindChat,
                tags: [MessageTagFfi(values: ["emoji", "party", peerURL]),
                       MessageTagFfi(values: ["emoji", "celebrate", peerURL]),
                       MessageTagFfi(values: ["emoji", "party-time", peerURL])],
                timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil, mediaJson: nil,
                media: [], agentTextStreamJson: nil, groupSystem: nil,
                reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil, deleted: false,
                deletedByMessageIdHex: nil, invalidationStatus: nil)
            peerRow.media = [.accepted(attachmentIndex: 0, reference: received)]
            let peerMessage = ConversationMessageFfi(timeline: peerRow, references: ConversationMessageReferencesFfi(
                messageIdHex: peerMessageID, sender: peer, replyAuthor: nil, mentions: [], mentionsTruncated: false,
                replyMentions: [], replyMentionsTruncated: false, system: nil,
                reactions: ConversationReactionsFfi(totalCount: 0, totalKinds: 0, items: [], omittedKinds: 0)))
            snapshot.revision.sequence += 1
            snapshot.messages = [peerMessage] + snapshot.messages
            model.installConversationWindow(snapshot)

            let party = try #require(CustomEmojiShortcode("party"))
            let celebrate = try #require(CustomEmojiShortcode("celebrate"))
            // :celebrate: is an alias of the same image. The hyphenated
            // shortcode renders but is not NIP-30, so it is never offered.
            #expect(Set(model.customEmojiSendables.map(\.shortcode)) == [party, celebrate])
            let emoji = model.customEmojiUsed(in: "yay :party: :celebrate: :party-time:")
            #expect(emoji.map(\.shortcode) == [party, celebrate])

            var uploadCount = 0
            var uploadedURL = ""
            let version = groupRecord.encryptedMedia.version ?? .v2
            let sender = ConversationCustomEmojiSender(
                scopeProvider: { model.customEmojiSendScope },
                currentEpoch: { epoch },
                loadBytes: { item in
                    #expect(item.reference == received)
                    #expect(item.demand == .automatic)
                    return payload
                },
                upload: { _, request in
                    uploadCount += 1
                    let ciphertext = Self.hex(Data("cipher".utf8) + request.plaintext)
                    uploadedURL = "https://blossom.example.com/\(ciphertext)"
                    return MediaAttachmentReferenceFfi(
                        locators: [MediaLocatorFfi(kind: "blossom-v1", value: uploadedURL)],
                        ciphertextSha256: ciphertext, plaintextSha256: Self.hex(request.plaintext),
                        nonceHex: String(repeating: "3", count: 24), fileName: request.fileName,
                        mediaType: request.mediaType, version: version, sourceEpoch: epoch,
                        dim: request.dim, thumbhash: request.thumbhash)
                },
                sendMessage: { scope, caption, attachments, tags in
                    do {
                        let summary = try await client.sendTaggedMedia(accountRef: scope.accountRef, groupIdHex: scope.groupIdHex,
                                                                     attachments: attachments, caption: caption, tags: tags)
                        #expect(summary.acceptDisposition != .published)
                    } catch {
                        Issue.record(error, "MDK tagged-media send failed before the app classified the error")
                        throw error
                    }
                }
            )

            try await sender.sendMessage(text: "yay :party: :celebrate: :party-time:", replyTargetId: nil, emoji: emoji)
            #expect(uploadCount == 1)

            // MDK stored a kind-9 carrying the caption, the emoji tag naming our
            // upload, and that upload as an attachment; the resolver draws it
            // inline and leaves nothing for the media grid.
            var readBack = try await readSnapshot()
            let sent = try #require(readBack.messages.first {
                $0.timeline.direction == "sent" && $0.timeline.kind == MessageSemantics.kindChat
            }).timeline
            #expect(sent.plaintext == "yay :party: :celebrate: :party-time:")
            #expect(sent.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL])))
            #expect(sent.tags.contains(MessageTagFfi(values: ["emoji", "celebrate", uploadedURL])))
            // One image, one attachment slot, even with two shortcodes.
            #expect(sent.media.count == 1)
            #expect(!sent.tags.contains { $0.values.first == "emoji" && $0.values.dropFirst().first == "party-time" })
            let attachments = MessageMediaAttachment.displayItems(fromOutcomes: sent.media, ownerId: "msg:\(sent.messageIdHex)",
                messageId: sent.messageIdHex, sourceMessageId: sent.sourceMessageIdHex)
            let resolution = CustomEmojiResolver.resolve(text: sent.plaintext, tags: sent.tags, attachments: attachments)
            #expect(resolution.shortcodes == [party, celebrate])
            #expect(resolution.inline[party]?.reference?.locators.first?.value == uploadedURL)
            #expect(resolution.gridItems.isEmpty)

            // A second message reuses the uploaded reference: no second upload.
            try await sender.sendMessage(text: "again :party:", replyTargetId: nil, emoji: [emoji[0]])
            #expect(uploadCount == 1)
            readBack = try await readSnapshot()
            #expect(readBack.messages.filter {
                $0.timeline.tags.contains(MessageTagFfi(values: ["emoji", "party", uploadedURL]))
            }.count == 2)

            // The view model renders it through the #1136 path.
            readBack.revision.sequence = snapshot.revision.sequence + 1
            readBack.messages = [peerMessage] + readBack.messages
            model.installConversationWindow(readBack)
            let item = try #require(model.timeline.first { item in
                if case .message(let record, _) = item.kind { return record.messageIdHex == sent.messageIdHex }
                return false
            })
            #expect(model.customEmoji(for: item).shortcodes == [party, celebrate])
            #expect(model.mediaItems(for: item).isEmpty)
            #expect(relay.didRefusePublication)
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }
}

/// Serves empty history and refuses publication with a retryable relay response.
private nonisolated final class CustomEmojiTestRelay: Sendable {
    private let queue = DispatchQueue(label: "CustomEmojiTestRelay")
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())
    private let refusedPublication = OSAllocatedUnfairLock(initialState: false)

    var didRefusePublication: Bool { refusedPublication.withLock { $0 } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                        return
                    }
                    continuation.resume(returning: "ws://127.0.0.1:\(port.rawValue)")
                case .waiting(let error), .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.withLock { $0.append(connection) }
                connection.start(queue: queue)
                receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            connections.withLock { connections in
                connections.forEach { $0.cancel() }
                connections.removeAll()
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                connection.cancel()
                return
            }
            if let data, let request = try? JSONSerialization.jsonObject(with: data) as? [Any], request.count > 1 {
                var response: [Any]?
                if request.first as? String == "REQ", let subscriptionID = request[1] as? String {
                    response = ["EOSE", subscriptionID]
                } else if request.first as? String == "EVENT", let event = request[1] as? [String: Any],
                          let eventID = event["id"] as? String {
                    refusedPublication.withLock { $0 = true }
                    response = ["OK", eventID, false, "rate-limited: publication unavailable in this test"]
                }
                if let response, let data = try? JSONSerialization.data(withJSONObject: response) {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "relay response", metadata: [metadata])
                    connection.send(content: data, contentContext: context, completion: .idempotent)
                }
            }
            receive(on: connection)
        }
    }
}

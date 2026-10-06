import Foundation
import Network
import os
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct GroupModerationBindingTests {
    @Test func retryableReportsRemainPendingUntilSourceAuthorizedModerationApplies() async throws {
        let relay = try ModerationTestRelay()
        defer { relay.stop() }
        let relayURL = try await relay.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moderation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try Marmot.newWithConfiguration(rootPath: root.path, relayUrls: [relayURL],
            options: MarmotOptions(relayPolicy: .allowLoopback, attachmentAcquisitionMode: .hostManaged))
        let watchdog = Task {
            try await Task.sleep(for: MarmotFixtureWatchdog.deadlineOnlyADeadlockCanReach)
            Issue.record("Moderation fixture exceeded its deadline")
            try await client.shutdownAndClose()
        }
        defer { watchdog.cancel() }
        do {
            try await client.start()
            let account = try await client.createIdentityWithProfile(
                defaultRelays: [relayURL], bootstrapRelays: [relayURL]
            ).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Moderation test", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let live = try await client.groupConversationSnapshot(accountRef: account.label, groupIdHex: group.groupIdHex)
            #expect(live.managementState.isSelfAdmin)
            // Admission alone does not establish that the worker retained a reportable target.
            let sent = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Reported text", clientToken: UUID().uuidString)
            let messageID = sent.messageIdHex
            #expect(!messageID.isEmpty)
            let target = try await waitForTarget(client, account: account.label, group: group.groupIdHex, token: sent.clientToken)
            #expect(target.messageIds.contains(messageID))
            #expect(target.acceptDisposition != .published)
            _ = try await client.reportMessage(accountRef: account.label, groupIdHex: group.groupIdHex,
                messageId: messageID, reason: .spam, explanation: "Please review")
            let reports = try client.contentReports(accountRef: account.label, groupIdHex: group.groupIdHex,
                messageId: nil, after: nil, limit: 100)
            let report = try #require(reports.reports.first)
            #expect(report.messageIdHex == messageID)
            #expect(!report.dismissed)
            let before = try #require(try client.reportedMessage(accountRef: account.label,
                groupIdHex: group.groupIdHex, messageId: messageID))
            #expect(before.hasReports)
            #expect(before.plaintext == "Reported text")
            let dismissal = try await client.dismissReports(accountRef: account.label, groupIdHex: group.groupIdHex,
                reportIds: [report.reportIdHex], explanation: "")
            let dismissed = try client.contentReports(accountRef: account.label, groupIdHex: group.groupIdHex,
                messageId: nil, after: nil, limit: 100)
            #expect(dismissal.acceptDisposition != .published)
            #expect(dismissed.reports.first?.dismissed == false)
            let preserved = try #require(try client.reportedMessage(accountRef: account.label,
                groupIdHex: group.groupIdHex, messageId: messageID))
            #expect(!preserved.deleted)
            #expect(preserved.plaintext == "Reported text")
            let deletion = try await client.deleteMessage(accountRef: account.label, groupIdHex: group.groupIdHex, targetMessageId: messageID)
            let removed = try #require(try client.reportedMessage(accountRef: account.label,
                groupIdHex: group.groupIdHex, messageId: messageID))
            #expect(deletion.acceptDisposition != .published)
            #expect(!removed.deleted)
            #expect(removed.plaintext == "Reported text")
            #expect(removed.media.isEmpty)
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex,
                mode: .latest, messageIdHex: nil, initialRows: nil, timeoutMs: 30_000)
            let snapshot = try #require(window.snapshot())
            #expect(snapshot.messages.allSatisfy { ![1984, 1985, 4891].contains($0.timeline.kind) })
            #expect(snapshot.header.epoch == nil)
            #expect(!snapshot.header.capabilities.canSend)
            #expect(relay.didRefusePublication)
            await window.cancel()
            try await client.shutdownAndClose()
        } catch {
            try? await client.shutdownAndClose()
            throw error
        }
    }

    private func waitForTarget(_ client: Marmot, account: String, group: String, token: String) async throws -> SendSummaryFfi {
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            let status = try await Task.detached {
                try client.localSendStatus(accountRef: account, groupIdHex: group, clientToken: token)
            }.value
            if case .completed(let summary) = status { return summary }
            try #require(status != nil && status != .rejected, "The moderation target must survive local send processing")
            try #require(ContinuousClock.now < deadline, "The moderation target did not finish local send processing")
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// Serves empty history and refuses publication with a retryable relay response.
private nonisolated final class ModerationTestRelay: Sendable {
    private let queue = DispatchQueue(label: "ModerationTestRelay")
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

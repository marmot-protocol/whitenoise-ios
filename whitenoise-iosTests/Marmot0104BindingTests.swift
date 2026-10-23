import Foundation
import Network
import os
import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .tags(.runtime))
struct Marmot0104BindingTests {
    @Test func acceptedTokenSurvivesRestartAndRejectsChangedRequests() async throws {
        let relay = try LocalAdmissionTestRelay()
        defer { relay.stop() }
        let relayURL = try await relay.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAdmission-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func openRuntime() throws -> Marmot {
            try Marmot.newWithConfiguration(rootPath: root.path, relayUrls: [relayURL],
                options: MarmotOptions(relayPolicy: .allowLoopback, attachmentAcquisitionMode: .hostManaged))
        }
        let client = try openRuntime()
        let watchdog = Task {
            try await Task.sleep(for: MarmotFixtureWatchdog.deadlineOnlyADeadlockCanReach)
            Issue.record("Durable token test stalled")
            try await client.shutdownAndClose()
        }
        defer { watchdog.cancel() }
        do {
            try await client.start()
            let account = try await client.createIdentityWithProfile(
                defaultRelays: [relayURL], bootstrapRelays: [relayURL]).account
            let group = try await client.createGroupWithOptionsDetailed(accountRef: account.label,
                name: "Local admission", memberRefs: [], options: CreateGroupOptionsFfi(
                    description: nil, initialImage: nil, disappearingMessageSecs: 0))
            let token = UUID().uuidString
            let accepted = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            // Admission only queues the send. Establish engine completion before testing reuse.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            var status = try client.localSendStatus(accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token)
            while status == .queued || status == .engineOwned, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                status = try client.localSendStatus(accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
            }
            guard case .completed = status else {
                Issue.record("The relay-backed fixture must complete its send before testing token reuse")
                try await client.shutdownAndClose()
                return
            }
            let repeated = try await client.sendTextWithClientToken(accountRef: account.label,
                groupIdHex: group.groupIdHex, text: "Durable message", clientToken: token)
            #expect(accepted == repeated)
            #expect(accepted.clientToken == token)
            #expect(!accepted.messageIdHex.isEmpty)
            #expect(try client.localSendStatus(accountRef: account.label,
                groupIdHex: group.groupIdHex, clientToken: token) != nil)
            do {
                _ = try await client.sendTextWithClientToken(accountRef: account.label,
                    groupIdHex: group.groupIdHex, text: "Changed request", clientToken: token)
                Issue.record("A token must not be reassigned to a different request")
            } catch MarmotKitError.Runtime(let details) {
                #expect(details.contains("client token is already bound to another submission"))
            }
            let window = try await client.openConversationWindow(accountRef: account.label, groupIdHex: group.groupIdHex,
                mode: .automatic, messageIdHex: nil, initialRows: 50, timeoutMs: 0)
            let snapshot = try #require(window.snapshot())
            #expect(snapshot.messages.filter { $0.timeline.clientToken == token }.count == 1)
            await window.cancel()
            try await client.shutdownAndClose()
            let restarted = try openRuntime()
            do {
                let restoredStatus = try restarted.localSendStatus(accountRef: account.label,
                    groupIdHex: group.groupIdHex, clientToken: token)
                #expect(restoredStatus == status)
                try await restarted.shutdownAndClose()
            } catch {
                try? await restarted.shutdownAndClose()
                throw error
            }
        } catch {
            try? await client.shutdownAndClose()
            throw error
        }
    }

    @Test func attachmentGenerationsRejectStaleAndConsumedPermissions() async throws {
        let client = try MarmotClient.testClient()
        let watchdog = MarmotFixtureWatchdog.start("Attachment permission test stalled", breaking: client)
        defer { watchdog.cancel() }
        do {
            try await client.startRuntime()
            let account = try await client.marmot.createIdentityWithProfile(
                defaultRelays: client.relayUrls, bootstrapRelays: client.relayUrls).account
            let first = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.label)
            let second = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.label)
            let permission = AttachmentAutomaticPermissionFfi(images: true, videos: false, audio: false, files: false)
            #expect(try await !client.marmot.setAttachmentAutomaticPermission(accountRef: account.label,
                generation: first, permission: permission))
            #expect(try await client.marmot.setAttachmentAutomaticPermission(accountRef: account.label,
                generation: second, permission: permission))
            #expect(try await !client.marmot.setAttachmentAutomaticPermission(accountRef: account.label,
                generation: second, permission: permission))
            _ = try await client.signOut(accountRef: account.label, deleteKeyPackages: false)
            await #expect(throws: MarmotKitError.AttachmentAccountSignedOut) {
                _ = try await client.marmot.beginAttachmentPermissionUpdate(accountRef: account.label)
            }
            try await client.marmot.shutdownAndClose()
        } catch {
            try? await client.marmot.shutdownAndClose()
            throw error
        }
    }

    @Test func terminalAttachmentStatesDoNotWaitOrRetryAutomatically() {
        for state in [AttachmentTransferStateFfi.previouslyAcquiredUnavailable, .completedUnretained,
                      .retryExhausted, .removed, .cancelled, .failed, .policyBlocked, .paused, .unavailable] {
            #expect(!AttachmentAcquisitionPresentation.canAwait(state))
        }
        for state in [AttachmentTransferStateFfi.queued, .downloading, .ready, .retryScheduled] {
            #expect(AttachmentAcquisitionPresentation.canAwait(state))
        }
    }
}

/// Isolated relay: empty history and successful publication acknowledgments for the binding fixture.
private nonisolated final class LocalAdmissionTestRelay: Sendable {
    private let queue = DispatchQueue(label: "LocalAdmissionTestRelay")
    private let listener: NWListener
    private let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

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
                    response = ["OK", eventID, true, ""]
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

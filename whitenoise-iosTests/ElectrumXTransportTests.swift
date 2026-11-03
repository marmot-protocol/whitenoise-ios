import Foundation
import Network
import Security
import Testing
@testable import whitenoise_ios

/// Tests for the reply-envelope id walker the ElectrumX transport uses to
/// filter server notifications from JSON-RPC replies. Fixtures are ported
/// from whitenoise-linux `scripts/nc_shim_selftest.c` (79447095f2).
///
/// The selftest's frame-overflow fixtures (two-fragment attack, oversize
/// single frame) have no direct analog: Network.framework owns RFC 6455
/// framing, masking, and defragmentation, so the C shim's byte-level length
/// arithmetic does not exist in this port. The hard message cap the shim
/// applied is carried over as a post-delivery size check in the transport.
struct ElectrumXTransportTests {
    private func messageId(_ envelope: String) -> Int? {
        ElectrumXTransport.messageId(in: Data(envelope.utf8))
    }

    @Test func nestedIdReturnsTopLevelId() {
        // The reviewer's fixture: a nested "id" must not win over the
        // envelope's own id.
        #expect(messageId("{\"result\":{\"id\":99},\"id\":2}") == 2)
    }

    @Test func whitespaceAroundIdIsTolerated() {
        #expect(messageId("{\"id\" : 2,\"result\":null}") == 2)
    }

    @Test func missingIdReturnsNil() {
        #expect(messageId("{\"result\":null}") == nil)
    }

    @Test func idInsideAStringValueIsIgnored() {
        #expect(messageId("{\"data\":\"has \\\"id\\\": inside\",\"id\":7}") == 7)
    }

    @Test func errorEnvelopeIdIsExtracted() {
        let envelope = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"nope\"},\"id\":42}"
        #expect(messageId(envelope) == 42)
    }

    @Test func notificationWithoutIdReturnsNil() {
        // ElectrumX subscription push: must not be mistaken for a reply.
        let envelope = "{\"method\":\"blockchain.headers.subscribe\",\"params\":[{\"hex\":\"...\",\"height\":1}]}"
        #expect(messageId(envelope) == nil)
    }

    @Test func nonIntegerIdReturnsNil() {
        #expect(messageId("{\"id\":null,\"result\":null}") == nil)
        #expect(messageId("{\"id\":\"2\",\"result\":null}") == nil)
    }

    @Test func negativeIdIsExtracted() {
        #expect(messageId("{\"id\":-3,\"result\":null}") == -3)
    }

    @Test func unbalancedEnvelopeReturnsNil() {
        #expect(messageId("}}{\"id\":2}") == nil)
    }

    @Test func hardMessageCapMatchesUpstream() {
        // NC_HARD_FRAME_CAP in nc_shim.c.
        #expect(ElectrumXTransport.hardMessageCap == 16 * 1024 * 1024)
    }

    @Test func publicKeyPinHashesDERSubjectPublicKeyInfo() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let raw = try #require(SecKeyCopyExternalRepresentation(key, nil) as? Data)
        let spki = try #require(ElectrumXTransport.subjectPublicKeyInfo(for: key))
        // DER id-ecPublicKey + prime256v1, then the raw key in a bit string.
        #expect(spki.dropFirst(2).prefix(21) == Data([
            0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        ]))
        #expect(spki.contains(Data([0x03, UInt8(raw.count + 1), 0x00])))
        #expect(spki.suffix(raw.count) == raw)
    }

    @Test func readTimeoutClosesARealStalledSocket() async throws {
        let server = try await StallingTCPServer()
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp
        )
        try await ElectrumXTransport.start(connection)
        let cancellation = ConnectionCancellation(connection: connection)
        defer { cancellation.cancel() }

        await #expect(throws: ElectrumXTransport.TransportError.timeout) {
            _ = try await ElectrumXTransport.roundTrip(
                on: connection,
                request: "{}",
                wantId: 1,
                readTimeoutNanoseconds: 50_000_000,
                cancellation: cancellation
            )
        }
    }

    @Test func cancellationUnblocksARealSocketRead() async throws {
        let server = try await StallingTCPServer()
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp
        )
        try await ElectrumXTransport.start(connection)
        let cancellation = ConnectionCancellation(connection: connection)
        defer { cancellation.cancel() }
        let read = Task {
            try await ElectrumXTransport.roundTrip(
                on: connection,
                request: "{}",
                wantId: 1,
                readTimeoutNanoseconds: 15_000_000_000,
                cancellation: cancellation
            )
        }
        await Task.yield()
        read.cancel()
        await #expect(throws: (any Error).self) { _ = try await read.value }
    }
}

/// Accepts local TCP connections and deliberately never writes a response.
// NWListener/NWConnection are thread-safe; accepted connections are confined to `queue`.
// swiftlint:disable:next no_unchecked_sendable
private final class StallingTCPServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ElectrumXTransportTests.stalling-server")
    private var connections: [NWConnection] = []

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.start(queue: queue)
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

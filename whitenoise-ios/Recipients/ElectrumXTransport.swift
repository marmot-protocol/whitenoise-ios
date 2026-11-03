import CryptoKit
import Foundation
import Network
import Security
import Synchronization

/// One-shot ElectrumX JSON-RPC over WebSocket Secure, ported from
/// whitenoise-linux `app/nc_shim.c` (79447095f2, cross-build fix 271f0a4a04).
///
/// One call = one RPC = one connection. Network.framework's WebSocket client
/// performs the RFC 6455 handshake, masks client frames, and defragments
/// messages, so the C shim's byte-level frame codec has no equivalent here.
/// What IS carried over:
///
///   * TLS trust is endpoint-specific: pinned operators use leaf-pubkey
///     SHA-256 equality (the moral equivalent of CURLOPT_PINNEDPUBLICKEY),
///     while the other endpoints retain system CA and hostname verification.
///   * Replies are filtered to the request's `id` by a byte-level walker that
///     only matches `"id"` at object depth 1 (exact port of `nc_message_id`),
///     then re-parsed with a real JSON parser before any payload is trusted.
///   * A hard message cap (16 MiB) so a hostile or broken server cannot pin
///     the resolver buffering an unbounded reply; the resolver additionally
///     bounds replies at 128 KiB.
///
/// The linux cross-build fix (64-bit deadlines on LLP64, Win socket patterns)
/// has no analog: Network.framework is the same code path on device and
/// simulator, and Swift's `UInt64` nanosecond deadlines are width-stable
/// across arm64 targets.
nonisolated enum ElectrumXTransport {
    /// Matches `NC_HARD_FRAME_CAP` in nc_shim.c.
    static let hardMessageCap = 16 * 1024 * 1024

    enum TransportError: Error, Equatable {
        case connectionFailed
        case timeout
        case messageTooLarge
        case noMatchingReply
    }

    /// One ElectrumX endpoint. `pinnedPublicKeySHA256` is the base64 of the
    /// SHA-256 over the leaf certificate's DER SubjectPublicKeyInfo — the
    /// same digest the linux rotation runbook produces with
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256`.
    struct Server: Equatable, Sendable {
        let host: String
        let port: UInt16
        let path: String
        let pinnedPublicKeySHA256: String?
        /// Certificate/SNI identity. IP endpoints use their operator's DNS
        /// name so the same leaf-key pin and TLS identity apply to both.
        let tlsServerName: String

        init(
            host: String,
            port: UInt16,
            path: String = "/",
            pinnedPublicKeySHA256: String?,
            tlsServerName: String? = nil
        ) {
            self.host = host
            self.port = port
            self.path = path
            self.pinnedPublicKeySHA256 = pinnedPublicKeySHA256
            self.tlsServerName = tlsServerName ?? host
        }
    }

    /// Opens one pinned WSS connection to `server`, sends `request` (a
    /// JSON-RPC 2.0 body already carrying `wantId`), and returns the first
    /// reply message whose top-level `"id"` equals `wantId`. Server pushes
    /// (subscription notifications) carry no top-level id and are skipped.
    ///
    /// The whole "connect + handshake + one round trip" shares the
    /// `timeoutNanoseconds` budget, mirroring the per-server deadline the C
    /// shim applies. Throws on dial, handshake, timeout, or close-without-
    /// matching-reply.
    static func call(
        server: Server,
        request: String,
        wantId: Int,
        connectTimeoutNanoseconds: UInt64 = 10_000_000_000,
        readTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) async throws -> Data {
        try await performCall(
            server: server,
            request: request,
            wantId: wantId,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds,
            readTimeoutNanoseconds: readTimeoutNanoseconds
        )
    }

    private static let networkQueue = DispatchQueue(
        label: "dev.ipf.whitenoise.ios.electrumx",
        qos: .utility
    )

    private static func performCall(
        server: Server,
        request: String,
        wantId: Int,
        connectTimeoutNanoseconds: UInt64,
        readTimeoutNanoseconds: UInt64
    ) async throws -> Data {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, server.tlsServerName)
        if let encodedPin = server.pinnedPublicKeySHA256 {
            guard let pin = Data(base64Encoded: encodedPin), pin.count == 32 else {
                throw TransportError.connectionFailed
            }
            // A pin replaces chain-of-trust only for this endpoint. Endpoints
            // without a pin retain Network.framework's normal CA/hostname check.
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, trust, complete in
                    complete(leafPublicKeySHA256(from: trust) == pin)
                },
                networkQueue
            )
        }
        let tcp = NWProtocolTCP.Options()
        // Configure the connect deadline before starting TCP/TLS. The async
        // start phase below enforces the same bound and cancels real I/O.
        tcp.connectionTimeout = Int(connectTimeoutNanoseconds / 1_000_000_000)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        guard let port = NWEndpoint.Port(rawValue: server.port) else {
            throw TransportError.connectionFailed
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: port,
            using: parameters
        )
        let cancellation = ConnectionCancellation(connection: connection)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await withPhaseTimeout(nanoseconds: connectTimeoutNanoseconds, onTimeout: {
                cancellation.cancel()
            }) {
                try await start(connection)
            }
            return try await roundTrip(
                on: connection,
                request: request,
                wantId: wantId,
                readTimeoutNanoseconds: readTimeoutNanoseconds,
                cancellation: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func roundTrip(
        on connection: NWConnection,
        request: String,
        wantId: Int,
        readTimeoutNanoseconds: UInt64,
        cancellation: ConnectionCancellation
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withPhaseTimeout(nanoseconds: readTimeoutNanoseconds, onTimeout: {
                cancellation.cancel()
            }) {
                try await send(Data(request.utf8), on: connection)
                while true {
                    let message = try await receiveMessage(from: connection)
                    guard message.count <= hardMessageCap else {
                        throw TransportError.messageTooLarge
                    }
                    guard messageId(in: message) == wantId else { continue }
                    return message
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func withPhaseTimeout<Value: Sendable>(
        nanoseconds: UInt64,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                onTimeout()
                throw TransportError.timeout
            }
            guard let first = try await group.next() else { throw TransportError.connectionFailed }
            group.cancelAll()
            return first
        }
    }

    /// SHA-256 of the leaf certificate's public key (DER
    /// SubjectPublicKeyInfo), or nil when the trust object does not present
    /// one. This is the digest `CURLOPT_PINNEDPUBLICKEY` compares against.
    static func leafPublicKeySHA256(from trust: sec_trust_t) -> Data? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let spki = subjectPublicKeyInfo(for: key)
        else { return nil }
        return Data(SHA256.hash(data: spki))
    }

    /// SecKey returns PKCS#1 for RSA and X9.63 for EC public keys. Curl's
    /// pinned-public-key contract hashes the enclosing DER SPKI instead.
    static func subjectPublicKeyInfo(for key: SecKey) -> Data? {
        guard let external = SecKeyCopyExternalRepresentation(key, nil) as? Data,
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? NSNumber
        else { return nil }

        let algorithm: Data
        if keyType == (kSecAttrKeyTypeRSA as String) {
            algorithm = Data([0x30, 0x0d, 0x06, 0x09,
                              0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
                              0x05, 0x00])
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            let curveOID: [UInt8]
            switch bits.intValue {
            case 256: curveOID = [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
            case 384: curveOID = [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22]
            case 521: curveOID = [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23]
            default: return nil
            }
            algorithm = der(0x30, contents: Data(
                [0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01] + curveOID
            ))
        } else {
            return nil
        }
        let bitString = der(0x03, contents: Data([0]) + external)
        return der(0x30, contents: algorithm + bitString)
    }

    private static func der(_ tag: UInt8, contents: Data) -> Data {
        var result = Data([tag])
        let length = contents.count
        if length < 128 {
            result.append(UInt8(length))
        } else {
            var bigEndian = UInt(length).bigEndian
            let bytes = withUnsafeBytes(of: &bigEndian) { Data($0) }
            let significant = bytes.drop(while: { $0 == 0 })
            result.append(0x80 | UInt8(significant.count))
            result.append(contentsOf: significant)
        }
        result.append(contentsOf: contents)
        return result
    }

    static func start(_ connection: NWConnection) async throws {
        let gate = ThrowingContinuationGate<Void>()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    gate.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    gate.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    gate.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    static func receiveMessage(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    // Close frame or empty delivery: the ElectrumX server hung
                    // up before answering.
                    continuation.resume(throwing: TransportError.noMatchingReply)
                }
            }
        }
    }

    /// Extracts the top-level `"id"` from a JSON-RPC 2.0 reply envelope.
    ///
    /// Correctness contract (ported line-for-line from `nc_message_id` in
    /// nc_shim.c): return the integer value of the key `"id"` at object depth
    /// 1 of the outermost JSON value. Return nil when the envelope is not a
    /// JSON object, when `"id"` is missing at depth 1, when it is not an
    /// integer, or when the buffer is not well-formed enough to walk. Nested
    /// `{"result":{"id":99},"id":2}` returns 2; whitespace between the colon
    /// and the number is allowed; `"id"` occurring inside a string value is
    /// ignored; `"id"` occurring at a nested depth is ignored.
    ///
    /// This walker only tracks (a) string state with backslash escapes and
    /// (b) structural depth via `{ [ ] }`. That is sufficient for the
    /// ElectrumX subset of JSON-RPC 2.0 the resolver speaks — one flat
    /// envelope per reply. Callers re-validate the envelope with a real JSON
    /// parser before trusting any payload; this scanner exists only to filter
    /// server notifications from replies at the socket layer.
    static func messageId(in buffer: Data) -> Int? {
        var depth = 0 // 0 = before outer, 1 = inside outer object, >1 = nested
        var inString = false
        var escaped = false
        var index = 0
        let bytes = [UInt8](buffer)
        let count = bytes.count
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")

        while index < count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                index += 1
                continue
            }
            if byte == quote {
                // Only match `"id"` at depth 1 (a key of the outer envelope).
                if depth == 1,
                   index + 3 < count,
                   bytes[index + 1] == UInt8(ascii: "i"),
                   bytes[index + 2] == UInt8(ascii: "d"),
                   bytes[index + 3] == quote
                {
                    var cursor = index + 4
                    while cursor < count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    if cursor >= count || bytes[cursor] != UInt8(ascii: ":") {
                        // `"id"` occurred as a value or without a colon — skip.
                        index = cursor
                        continue
                    }
                    cursor += 1
                    while cursor < count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    if cursor >= count { return nil }
                    var negative = false
                    if bytes[cursor] == UInt8(ascii: "-") {
                        negative = true
                        cursor += 1
                    }
                    var value = 0
                    var digits = 0
                    while cursor < count, bytes[cursor] >= UInt8(ascii: "0"),
                          bytes[cursor] <= UInt8(ascii: "9"), digits < 10
                    {
                        value = value * 10 + Int(bytes[cursor] - UInt8(ascii: "0"))
                        cursor += 1
                        digits += 1
                    }
                    if digits == 0 {
                        // `"id"` at depth 1 but not an integer (null / string).
                        return nil
                    }
                    return negative ? -value : value
                }
                inString = true
                index += 1
                continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                if depth < 0 { return nil }
            }
            index += 1
        }
        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}

/// `NWConnection.cancel()` is documented as safe from any queue. This wrapper
/// exists solely so task cancellation can close the connection across
/// isolation domains. Same pattern as PinnedHTTPSFetcher's.
// swiftlint:disable:next no_unchecked_sendable
nonisolated final class ConnectionCancellation: @unchecked Sendable {
    private let connection = Mutex<NWConnection?>(nil)

    init(connection: NWConnection) {
        self.connection.withLock { $0 = connection }
    }

    func cancel() {
        let taken = connection.withLock { connection -> NWConnection? in
            defer { connection = nil }
            return connection
        }
        taken?.cancel()
    }
}

/// State callbacks can race task cancellation. Taking and clearing the stored
/// continuation under a mutex makes every terminal state idempotent. Same
/// pattern as PinnedHTTPSFetcher's gate.
// swiftlint:disable:next no_unchecked_sendable
nonisolated private final class ThrowingContinuationGate<Value>: @unchecked Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Error>?>(nil)

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
    }
}

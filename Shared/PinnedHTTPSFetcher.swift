import Foundation
import Network
import Security

/// Minimal HTTPS/1.1 GET client for peer-controlled image URLs. It resolves a
/// hostname once, rejects the entire answer set if any address is private, then
/// connects to a validated numeric address. TLS still authenticates the
/// original hostname through SNI, so DNS cannot rebind between validation and
/// the socket connection.
nonisolated enum PinnedHTTPSFetcher {
    /// Upper bound on concurrent host resolutions across the process. Each
    /// resolution can pin a thread in uninterruptible getaddrinfo for the
    /// system resolver timeout, so exhausted slots fail fast rather than
    /// queueing more stuck work.
    static let maxConcurrentDnsResolutions = 6

    private static let dnsSlots = PinnedDNSResolutionSlots(limit: maxConcurrentDnsResolutions)

    /// Pure admission logic; the process-wide reservation owner holds its mutex.
    static func claimDnsSlot(_ inFlight: inout Int, limit: Int = maxConcurrentDnsResolutions) -> Bool {
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    struct Endpoint: Equatable, Sendable {
        let address: String
        let tlsServerName: String
        let port: UInt16
    }

    enum FetchError: Error, Equatable {
        case invalidRequest
        case httpStatus(Int)
        case malformedResponse
        case responseHeadersTooLarge
        case tooManyRedirects
    }

    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumRedirects = 5
    private static let ioChunkBytes = 64 * 1024
    private static let defaultTimeoutNanoseconds: UInt64 = 12_000_000_000
    private static let networkQueue = DispatchQueue(
        label: "dev.ipf.whitenoise.ios.pinned-https",
        qos: .utility
    )

    static func fetch(
        _ originalRequest: URLRequest,
        maximumResponseBytes: Int,
        resolver: @escaping HostResolutionGuard.Resolver = HostResolutionGuard.systemResolver,
        clock: any PinnedFetchClock = SystemPinnedFetchClock(),
        slots: PinnedDNSResolutionSlots? = nil,
        attempt: FetchAttempt? = nil
    ) async throws -> (Data, URLResponse) {
        guard maximumResponseBytes >= 0 else { throw FetchError.invalidRequest }
        let deadline = PinnedFetchDeadline(clock: clock)
        var request = originalRequest

        for redirectCount in 0...maximumRedirects {
            try deadline.check()
            let (data, response) = try await fetchOnce(
                request,
                maximumResponseBytes: maximumResponseBytes,
                resolver: resolver,
                deadline: deadline,
                slots: slots ?? dnsSlots,
                attempt: attempt
            )
            try deadline.check()
            guard (300..<400).contains(response.statusCode) else {
                guard (200..<300).contains(response.statusCode) else {
                    throw FetchError.httpStatus(response.statusCode)
                }
                return (data, response)
            }
            guard redirectCount < maximumRedirects else { throw FetchError.tooManyRedirects }
            request = try redirectedRequest(from: response, currentRequest: request)
        }
        throw FetchError.tooManyRedirects
    }

    static func endpoints(
        for url: URL,
        resolver: HostResolutionGuard.Resolver = HostResolutionGuard.systemResolver
    ) throws -> [Endpoint] {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              let port = UInt16(exactly: url.port ?? 443),
              // Mirror ContentSanitizer.imageURL: a peer-controlled URL must
              // not steer the pinned connection off the standard HTTPS port.
              port == 443
        else { throw FetchError.invalidRequest }
        return try HostResolutionGuard.resolvedPublicAddresses(host, resolver: resolver).map {
            Endpoint(address: $0, tlsServerName: host, port: port)
        }
    }

    static func redirectedRequest(
        from response: HTTPURLResponse,
        currentRequest: URLRequest
    ) throws -> URLRequest {
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let currentURL = currentRequest.url,
              let candidate = URL(string: location, relativeTo: currentURL)?.absoluteURL,
              let safeURL = ContentSanitizer.imageURL(candidate.absoluteString)
        else { throw URLError(.redirectToNonExistentLocation) }
        var redirected = currentRequest
        redirected.url = safeURL
        return redirected
    }

    private static func fetchOnce(
        _ request: URLRequest,
        maximumResponseBytes: Int,
        resolver: @escaping HostResolutionGuard.Resolver,
        deadline: PinnedFetchDeadline,
        slots: PinnedDNSResolutionSlots,
        attempt: FetchAttempt?
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              ContentSanitizer.imageURL(url.absoluteString) != nil,
              request.httpMethod == nil || request.httpMethod == "GET"
        else { throw FetchError.invalidRequest }

        let resolvedEndpoints = try await PinnedDNSWait.resolve(
            url: url,
            resolver: resolver,
            deadline: deadline,
            slots: slots
        )
        let requestData = try requestBytes(for: request)
        var lastError: Error = URLError(.cannotConnectToHost)
        for endpoint in resolvedEndpoints {
            let timeout = try deadline.attemptNanoseconds(maximum: timeoutNanoseconds(for: request))
            do {
                let result: PinnedResponse
                if let attempt {
                    result = try await attempt(requestData, url, endpoint, maximumResponseBytes, timeout)
                } else {
                    let response = try await fetch(
                        requestData: requestData, url: url, endpoint: endpoint,
                        maximumResponseBytes: maximumResponseBytes,
                        attemptExpiry: deadline.attemptExpiry(maximum: timeoutNanoseconds(for: request)),
                        deadline: deadline
                    )
                    result = PinnedResponse(data: response.0, response: response.1)
                }
                try deadline.check()
                return (result.data, result.response)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                try deadline.check()
                lastError = error
            }
        }
        throw lastError
    }

    /// Internal behavioral seam; production always uses the same native TLS adapter.
    typealias FetchAttempt = @Sendable (
        Data, URL, Endpoint, Int, UInt64
    ) async throws -> PinnedResponse

    private static func fetch(
        requestData: Data,
        url: URL,
        endpoint: Endpoint,
        maximumResponseBytes: Int,
        attemptExpiry: ContinuousClock.Instant,
        deadline: PinnedFetchDeadline
    ) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: PinnedResponse.self) { group in
            group.addTask {
                let response = try await performRequest(
                    requestData: requestData,
                    url: url,
                    endpoint: endpoint,
                    maximumResponseBytes: maximumResponseBytes,
                    deadline: deadline
                )
                return PinnedResponse(data: response.0, response: response.1)
            }
            group.addTask {
                try await Task.sleep(until: attemptExpiry, clock: .continuous)
                throw URLError(.timedOut)
            }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            group.cancelAll()
            return (first.data, first.response)
        }
    }

    private static func performRequest(
        requestData: Data,
        url: URL,
        endpoint: Endpoint,
        maximumResponseBytes: Int,
        deadline: PinnedFetchDeadline
    ) async throws -> (Data, HTTPURLResponse) {
        try deadline.check()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.tlsServerName)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(defaultTimeoutNanoseconds / 1_000_000_000)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw FetchError.invalidRequest
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.address),
            port: port,
            using: parameters
        )
        let cancellation = PinnedConnectionCancellation(connection: connection)
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try deadline.check()
            try await start(connection)
            try await send(requestData, on: connection)
            let rawLimit = maximumResponseBytes.addingReportingOverflow(maximumHeaderBytes)
            guard !rawLimit.overflow else { throw URLError(.dataLengthExceedsMaximum) }
            let raw = try await receiveAll(from: connection, maximumBytes: rawLimit.partialValue)
            return try parseResponse(raw, url: url, maximumResponseBytes: maximumResponseBytes)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func start(_ connection: NWConnection) async throws {
        let gate = PinnedFetchWaitGate<Void>()
        try await gate.wait { gate in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    gate.complete(.success(()))
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    gate.complete(.failure(error))
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    gate.complete(.failure(CancellationError()))
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        let gate = PinnedFetchWaitGate<Void>()
        try await gate.wait { gate in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    gate.complete(.failure(error))
                } else {
                    gate.complete(.success(()))
                }
            })
        }
    }

    private static func receiveAll(from connection: NWConnection, maximumBytes: Int) async throws -> Data {
        var received = Data()
        while true {
            let chunk = try await receive(from: connection)
            if let data = chunk.data, !data.isEmpty {
                guard data.count <= maximumBytes - received.count else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                received.append(data)
            }
            if chunk.complete { return received }
        }
    }

    private static func receive(from connection: NWConnection) async throws -> ReceivedChunk {
        let gate = PinnedFetchWaitGate<ReceivedChunk>()
        return try await gate.wait { gate in
            connection.receive(minimumIncompleteLength: 1, maximumLength: ioChunkBytes) {
                data,
                _,
                complete,
                error in
                if let error {
                    gate.complete(.failure(error))
                } else {
                    gate.complete(.success(ReceivedChunk(data: data, complete: complete)))
                }
            }
        }
    }

    static func requestBytes(for request: URLRequest) throws -> Data {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host
        else { throw FetchError.invalidRequest }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?\(query)" }
        let port = url.port ?? 443
        let bracketedHost = host.contains(":") ? "[\(host)]" : host
        let hostHeader = port == 443 ? bracketedHost : "\(bracketedHost):\(port)"
        var lines = ["GET \(target) HTTP/1.1", "Host: \(hostHeader)"]
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty,
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n")
            else { throw FetchError.invalidRequest }
            switch name.lowercased() {
            case "host", "connection", "accept-encoding", "content-length":
                continue
            default:
                lines.append("\(name): \(value)")
            }
        }
        lines.append("Accept-Encoding: identity")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        guard let data = lines.joined(separator: "\r\n").data(using: .utf8) else {
            throw FetchError.invalidRequest
        }
        return data
    }

    static func parseResponse(
        _ raw: Data,
        url: URL,
        maximumResponseBytes: Int
    ) throws -> (Data, HTTPURLResponse) {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = raw.range(of: separator) else { throw FetchError.malformedResponse }
        guard separatorRange.lowerBound <= maximumHeaderBytes else { throw FetchError.responseHeadersTooLarge }
        let headerData = raw[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw FetchError.malformedResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw FetchError.malformedResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw FetchError.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw FetchError.malformedResponse }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw FetchError.malformedResponse }
            if let existing = headers[name] {
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { throw FetchError.malformedResponse }
        let encodedBody = Data(raw[separatorRange.upperBound...])
        if response.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased().contains("chunked") == true {
            return (try decodeChunkedBody(encodedBody, maximumBytes: maximumResponseBytes), response)
        }
        if let lengthText = response.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int(lengthText),
                  length >= 0,
                  length <= maximumResponseBytes,
                  encodedBody.count >= length
            else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            return (Data(encodedBody.prefix(length)), response)
        }
        guard encodedBody.count <= maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        return (encodedBody, response)
    }

    private static func decodeChunkedBody(_ encoded: Data, maximumBytes: Int) throws -> Data {
        let crlf = Data("\r\n".utf8)
        var cursor = encoded.startIndex
        var decoded = Data()
        while true {
            guard let lineRange = encoded.range(of: crlf, in: cursor..<encoded.endIndex),
                  let sizeLine = String(data: encoded[cursor..<lineRange.lowerBound], encoding: .ascii),
                  let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0
            else { throw FetchError.malformedResponse }
            cursor = lineRange.upperBound
            if size == 0 {
                guard encoded.distance(from: cursor, to: encoded.endIndex) >= crlf.count,
                      encoded[cursor..<encoded.index(cursor, offsetBy: crlf.count)] == crlf
                else { throw FetchError.malformedResponse }
                return decoded
            }
            let remaining = encoded.distance(from: cursor, to: encoded.endIndex)
            guard size <= maximumBytes - decoded.count,
                  size <= remaining - crlf.count
            else { throw URLError(.dataLengthExceedsMaximum) }
            let chunkEnd = encoded.index(cursor, offsetBy: size)
            decoded.append(encoded[cursor..<chunkEnd])
            guard encoded[chunkEnd..<encoded.index(chunkEnd, offsetBy: crlf.count)] == crlf else {
                throw FetchError.malformedResponse
            }
            cursor = encoded.index(chunkEnd, offsetBy: crlf.count)
        }
    }

    private static func timeoutNanoseconds(for request: URLRequest) -> UInt64 {
        let seconds = request.timeoutInterval > 0 ? request.timeoutInterval : 12
        let nanoseconds = seconds * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds > 0, nanoseconds < Double(UInt64.max) else {
            return defaultTimeoutNanoseconds
        }
        return UInt64(nanoseconds)
    }

    // The response is fully constructed before crossing the task-group
    // boundary and is only read afterwards; Foundation has not annotated
    // HTTPURLResponse as Sendable on every supported OS toolchain.
    // swiftlint:disable:next no_unchecked_sendable
    struct PinnedResponse: @unchecked Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct ReceivedChunk: Sendable {
        let data: Data?
        let complete: Bool
    }
}

// `NWConnection.cancel()` is documented as safe from any queue. This wrapper
// exists solely so task cancellation can close the connection across isolation
// domains.
// swiftlint:disable:next no_unchecked_sendable
nonisolated private final class PinnedConnectionCancellation: @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.cancel()
    }
}

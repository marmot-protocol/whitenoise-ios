import Foundation

/// Resolves a NIP-05 address (`name@domain`) to a public key by fetching the
/// domain's `/.well-known/nostr.json` document. Requests ride the pinned
/// HTTPS fetcher, which resolves the host once, rejects private/loopback
/// answers, and bounds redirects, response size, and time — the address is
/// peer-controlled input, so nothing about it is trusted before that gate.
nonisolated enum Nip05Resolver {
    enum Resolution: Equatable {
        case resolved(accountIdHex: String)
        /// The document fetched but doesn't map this name to a valid pubkey.
        case noProfile
        /// Transport failure or malformed document.
        case failed
        /// The address can't produce a safe lookup URL.
        case invalidAddress
    }

    enum Verification: Equatable {
        case verified
        case mismatch
        case lookupFailed
    }

    typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)

    static let maximumDocumentBytes = 32 * 1024
    static let requestTimeout: TimeInterval = 8

    static let pinnedTransport: Transport = { request, maximumBytes in
        try await PinnedHTTPSFetcher.fetch(request, maximumResponseBytes: maximumBytes)
    }

    /// Builds the lookup URL, or `nil` when the address can't be queried
    /// safely: HTTPS only, no userinfo, default port only, percent-encoded
    /// name, and no IP-literal hosts (a numeric last label is never a TLD).
    static func lookupURL(name: String, domain: String) -> URL? {
        guard let sanitized = ContentSanitizer.profileAddress("\(name)@\(domain)") else { return nil }
        let host = String(sanitized.split(separator: "@")[1])
        let localName = String(sanitized.split(separator: "@")[0])
        guard !ContentSanitizer.isNonPublicAddressLiteral(host) else { return nil }
        guard let lastLabel = host.split(separator: ".").last,
              !lastLabel.allSatisfy(\.isNumber)
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/.well-known/nostr.json"
        components.queryItems = [URLQueryItem(name: "name", value: localName)]
        guard let url = components.url,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.host?.lowercased() == host
        else { return nil }
        return url
    }

    static func resolve(
        name: String,
        domain: String,
        transport: Transport = pinnedTransport
    ) async -> Resolution {
        guard let url = lookupURL(name: name, domain: domain) else { return .invalidAddress }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await transport(request, maximumDocumentBytes)
            guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed
            }
            guard let hex = accountIdHex(inDocument: document, name: name) else {
                return .noProfile
            }
            return .resolved(accountIdHex: hex)
        } catch {
            return .failed
        }
    }

    /// Strict document walk: `names` must be an object, the entry a string
    /// that normalizes to a 32-byte hex pubkey. Name comparison is
    /// case-insensitive per NIP-05's lowercase convention.
    static func accountIdHex(inDocument document: [String: Any], name: String) -> String? {
        guard let names = document["names"] as? [String: Any] else { return nil }
        let wanted = name.lowercased()
        let raw = (names[wanted] as? String)
            ?? names.first { $0.key.lowercased() == wanted }?.value as? String
        return raw.flatMap { Hex.normalized32Bytes($0) }
    }

    /// A declared NIP-05 address is verified only when it independently
    /// resolves back to the same pubkey it's displayed next to.
    static func verification(
        declaredAddress: String?,
        accountIdHex: String,
        transport: Transport = pinnedTransport
    ) async -> Verification {
        guard let address = RecipientIdentifierQuery.nip05Address(declaredAddress ?? "") else {
            return .mismatch
        }
        let resolution = await resolve(name: address.name, domain: address.domain, transport: transport)
        switch resolution {
        case .resolved(let resolvedHex):
            return resolvedHex == accountIdHex.lowercased() ? .verified : .mismatch
        case .noProfile, .invalidAddress:
            return .mismatch
        case .failed:
            return .lookupFailed
        }
    }
}

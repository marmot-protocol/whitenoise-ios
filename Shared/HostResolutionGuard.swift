import Foundation

/// SSRF defense against a public DNS name that *resolves* to an internal
/// address. `ContentSanitizer.imageURL` blocks private/loopback IP *literals*
/// in every spelling, but cannot see that `10-0-0-5.sslip.io` or
/// `127-0-0-1.nip.io` resolves to `10.0.0.5` / `127.0.0.1`. This resolves the
/// host and re-checks each resolved address against the resolved-address
/// policy, retaining configured fake-IP VPN DNS answers.
///
/// Remote image fetches consume `resolvedPublicAddresses` and connect directly
/// to one of those numeric endpoints while preserving the original hostname for
/// TLS SNI/trust evaluation. DNS is therefore not consulted again at connect
/// time, closing the DNS-rebinding window between validation and connection.
nonisolated enum HostResolutionGuard {
    /// Resolves a host to its numeric address strings. Injectable so tests can
    /// map a public-looking host to a private address without real DNS.
    typealias Resolver = @Sendable (String) -> [String]

    enum GuardError: Error, Equatable {
        case resolvesToPrivateAddress
        case resolutionFailed
    }

    /// `true` when `host` resolves to at least one private/loopback/link-local
    /// address — i.e. the fetch must be refused. An unresolvable host returns
    /// `false` (the real fetch will fail on its own); IP literals are handled
    /// upstream by the string allowlist.
    static func resolvesToPrivateAddress(
        _ host: String,
        resolver: Resolver = systemResolver
    ) -> Bool {
        resolver(host).contains { ContentSanitizer.isNonPublicResolvedAddress($0) }
    }

    /// Returns the complete resolved address set only when every answer is
    /// public. Empty/failed resolution is rejected rather than falling through
    /// to a second resolver that could produce a different, private answer.
    static func resolvedPublicAddresses(
        _ host: String,
        resolver: Resolver = systemResolver
    ) throws -> [String] {
        let addresses = resolver(host)
        guard !addresses.isEmpty else { throw GuardError.resolutionFailed }
        guard !addresses.contains(where: ContentSanitizer.isNonPublicResolvedAddress) else {
            throw GuardError.resolvesToPrivateAddress
        }
        return addresses
    }

    /// Default resolver backed by `getaddrinfo`, returning each resolved address
    /// as a numeric string (IPv4 dotted-quad or IPv6 hex) suitable for the
    /// literal classifier.
    static let systemResolver: Resolver = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var node = result
        while let current = node {
            if let sockaddr = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    sockaddr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    addresses.append(String(cString: buffer))
                }
            }
            node = current.pointee.ai_next
        }
        return addresses
    }
}

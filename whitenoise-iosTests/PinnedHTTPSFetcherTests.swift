import Foundation
import Synchronization
import Testing

@testable import whitenoise_ios

struct PinnedHTTPSFetcherTests {
    @Test(arguments: ["198.19.255.255", "100::1", "fec0::1", "2001:2::1"])
    func endpointsRejectSingleAndMixedNonPublicAnswers(address: String) throws {
        let url = try #require(URL(string: "https://cdn.example/image.png"))
        for answers in [[address], ["93.184.216.34", address]] {
            let resolver: HostResolutionGuard.Resolver = { _ in answers }
            #expect(throws: HostResolutionGuard.GuardError.resolvesToPrivateAddress) {
                try PinnedHTTPSFetcher.endpoints(for: url, resolver: resolver)
            }
        }
    }

    @Test func endpointsResolveOnceAndPreserveTLSHostname() throws {
        let url = try #require(URL(string: "https://cdn.example:443/avatar.png"))
        let calls = Mutex(0)
        let resolver: HostResolutionGuard.Resolver = { host in
            #expect(host == "cdn.example")
            calls.withLock { $0 += 1 }
            return ["93.184.216.34", "2001:4860:4860::8888"]
        }

        let endpoints = try PinnedHTTPSFetcher.endpoints(for: url, resolver: resolver)

        #expect(calls.withLock { $0 } == 1)
        #expect(endpoints == [
            .init(address: "93.184.216.34", tlsServerName: "cdn.example", port: 443),
            .init(address: "2001:4860:4860::8888", tlsServerName: "cdn.example", port: 443),
        ])
    }

    @Test func endpointsRejectNonStandardPorts() throws {
        // A peer URL must not steer the pinned TLS connection off port 443 —
        // the one dimension the host/address checks don't constrain.
        let url = try #require(URL(string: "https://cdn.example:8443/avatar.png"))
        let resolver: HostResolutionGuard.Resolver = { _ in ["93.184.216.34"] }

        #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try PinnedHTTPSFetcher.endpoints(for: url, resolver: resolver)
        }
    }

    @Test func endpointsRejectMixedPublicAndPrivateDNSAnswers() throws {
        let url = try #require(URL(string: "https://rebind.example/avatar.png"))
        let resolver: HostResolutionGuard.Resolver = { _ in ["93.184.216.34", "127.0.0.1"] }

        #expect(throws: HostResolutionGuard.GuardError.resolvesToPrivateAddress) {
            try PinnedHTTPSFetcher.endpoints(for: url, resolver: resolver)
        }
    }

    @Test func requestUsesOriginalHostAndDoesNotAllowHeaderOverrides() throws {
        let url = try #require(URL(string: "https://cdn.example:8443/a%20b.png?size=2"))
        var request = URLRequest(url: url)
        request.setValue("attacker.invalid", forHTTPHeaderField: "Host")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("image/png", forHTTPHeaderField: "Accept")

        let data = try PinnedHTTPSFetcher.requestBytes(for: request)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.hasPrefix("GET /a%20b.png?size=2 HTTP/1.1\r\n"))
        #expect(text.contains("\r\nHost: cdn.example:8443\r\n"))
        #expect(text.contains("\r\nAccept: image/png\r\n"))
        #expect(text.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(!text.contains("attacker.invalid"))
        #expect(!text.contains("gzip"))
    }

    @Test func parsesContentLengthResponse() throws {
        let url = try #require(URL(string: "https://example.com/a.png"))
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Type: image/png\r\n\r\ntestignored".utf8)

        let (body, response) = try PinnedHTTPSFetcher.parseResponse(
            raw,
            url: url,
            maximumResponseBytes: 4
        )

        #expect(body == Data("test".utf8))
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
    }

    @Test func parsesChunkedResponseAndEnforcesDecodedCap() throws {
        let url = try #require(URL(string: "https://example.com/a.png"))
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n".utf8)

        let (body, _) = try PinnedHTTPSFetcher.parseResponse(
            raw,
            url: url,
            maximumResponseBytes: 4
        )
        #expect(body == Data("test".utf8))

        #expect(throws: URLError.self) {
            try PinnedHTTPSFetcher.parseResponse(raw, url: url, maximumResponseBytes: 3)
        }
    }
}

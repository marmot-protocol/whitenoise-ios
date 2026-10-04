import Foundation
import Testing

@testable import whitenoise_ios

/// Regression coverage for whitenoise-ios#206: every redirect is parsed as a
/// new request, rechecked by the URL allowlist, then independently resolved and
/// pinned before the connection is made.
struct PinnedHTTPSRedirectTests {
    @Test func allowsRelativeRedirectToPublicHTTPSURL() throws {
        let currentURL = try #require(URL(string: "https://cdn.example/images/avatar.png"))
        let response = try #require(HTTPURLResponse(
            url: currentURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "../new.png"]
        ))

        let redirected = try PinnedHTTPSFetcher.redirectedRequest(
            from: response,
            currentRequest: URLRequest(url: currentURL)
        )

        #expect(redirected.url?.absoluteString == "https://cdn.example/new.png")
    }

    @Test(arguments: [
        "http://example.com/avatar.png",
        "https://localhost/avatar.png",
        "https://127.0.0.1/avatar.png",
        "https://169.254.169.254/latest/meta-data/",
        "https://[::1]/avatar.png",
        "https://[ff02::1]/avatar.png",
        "https://[2002:7f00:1::]/avatar.png",
        "https://198.18.0.1/avatar.png",
        "https://198.51.100.1/avatar.png",
        "https://[fec0::1]/avatar.png",
        "https://[2001:db8::1]/avatar.png",
        "https://[64:ff9b:1::1]/avatar.png",
    ])
    func refusesUnsafeRedirect(location: String) throws {
        let currentURL = try #require(URL(string: "https://cdn.example/avatar.png"))
        let response = try #require(HTTPURLResponse(
            url: currentURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": location]
        ))

        #expect(throws: URLError.self) {
            try PinnedHTTPSFetcher.redirectedRequest(
                from: response,
                currentRequest: URLRequest(url: currentURL)
            )
        }
    }

    @Test func redirectedHostnameIsResolvedOnceAndPinned() throws {
        let redirectURL = try #require(URL(string: "https://rebind.example/avatar.png"))
        let response = try #require(HTTPURLResponse(
            url: redirectURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        ))
        let redirected = try PinnedHTTPSFetcher.redirectedRequest(
            from: response,
            currentRequest: URLRequest(url: redirectURL)
        )
        let redirectedURL = try #require(redirected.url)
        let resolver: HostResolutionGuard.Resolver = { _ in ["93.184.216.34", "10.0.0.5"] }

        #expect(throws: HostResolutionGuard.GuardError.resolvesToPrivateAddress) {
            try PinnedHTTPSFetcher.endpoints(for: redirectedURL, resolver: resolver)
        }
    }
}

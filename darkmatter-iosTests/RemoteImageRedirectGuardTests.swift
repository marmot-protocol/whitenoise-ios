import Testing
import Foundation
@testable import darkmatter_ios

/// Regression coverage for darkmatter-ios#206: the remote image fetch must
/// re-validate every HTTP redirect target through the SSRF allowlist, not just
/// the initial URL. Without `RemoteImageRedirectGuard`, an allowlisted public
/// HTTPS endpoint could `302` the fetch to a loopback/private/internal host.
struct RemoteImageRedirectGuardTests {

    // MARK: - Pure allowlist helper

    @Test func allowsRedirectToPublicHttpsHost() {
        #expect(RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://example.com/a.png")))
        #expect(RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://8.8.8.8/a.png")))
    }

    @Test func refusesRedirectToLoopbackAndPrivateHosts() {
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "http://127.0.0.1:8080/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://127.0.0.1/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://localhost/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[::1]/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://10.1.2.3/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://192.168.1.10/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://169.254.169.254/latest/meta-data/")))
        // RFC 6598 CG-NAT / shared address space (100.64.0.0/10) and other
        // reserved IPv4 space reachable on-device/LAN (#244).
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://100.64.0.1/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://192.0.0.1/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://224.0.0.1/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://255.255.255.255/x")))
        // Legacy IPv4 literal and IPv4-mapped IPv6 spellings of loopback.
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://2130706433/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[::ffff:127.0.0.1]/x")))
    }

    @Test func refusesRedirectThatDowngradesToHttp() {
        // HTTPS→HTTP downgrade on the redirected hop, even to a public host.
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "http://example.com/a.png")))
    }

    /// darkmatter-ios#322: the IPv6 allowlist must block multicast (`ff00::/8`)
    /// and decode the embedded IPv4 of 6to4 (`2002::/16`) and Teredo
    /// (`2001:0000::/32`) so an internal v4 can't ride in through those
    /// transition prefixes — mirroring the IPv4-mapped/compatible decoding.
    @Test func refusesRedirectToIPv6MulticastAndTransitionEmbeddings() {
        // IPv6 multicast (all-nodes link-local, mDNS, site-local).
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[ff02::1]/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[ff02::fb]/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[ff05::1]/x")))
        // 6to4 (2002::/16) embedding loopback / link-local-metadata IPv4.
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2002:7f00:1::]/x")))
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2002:a9fe:a9fe::]/x")))
        // Teredo (2001:0000::/32) — branch-isolated rejection vectors so a
        // regression in either embedded-IPv4 check fails on its own.
        // Public server (8.8.8.8) + private client (~127.0.0.1): only the
        // obfuscated-client decode (bytes[12..16] ^ 0xff) can reject this.
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2001:0:808:808:0:0:80ff:fffe]/x")))
        // Private server (169.254.169.254) + public client (8.8.8.8): only the
        // plaintext server decode (bytes[4..8]) can reject this.
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2001:0:a9fe:a9fe:0:0:f7f7:f7f7]/x")))
    }

    /// Public IPv6 transition addresses must stay allowed: 6to4 / Teredo
    /// wrapping a public IPv4, and a global-unicast 2001 prefix that is not
    /// Teredo, are legitimate public hosts and must not be over-blocked.
    @Test func allowsRedirectToPublicIPv6TransitionAddresses() {
        // 6to4 wrapping public 8.8.8.8.
        #expect(RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2002:808:808::]/x")))
        // Global-unicast 2001 prefix that is not Teredo (bytes[2..4] != 0000):
        // a genuinely routable public host (Google public DNS) must stay allowed.
        #expect(RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2001:4860:4860::8888]/x")))
        // Teredo with a public server and public client IPv4.
        #expect(RemoteImageRedirectGuard.isRedirectAllowed(to: URL(string: "https://[2001:0:808:808:0:0:f7f7:f7f7]/x")))
    }

    @Test func refusesNilRedirectTarget() {
        #expect(!RemoteImageRedirectGuard.isRedirectAllowed(to: nil))
    }

    // MARK: - Delegate callback behavior

    /// A stubbed `302 Location: http://127.0.0.1/...` redirect must be refused:
    /// the delegate hands `nil` to the completion handler, terminating the
    /// chain so the request is never issued to the loopback host.
    @Test func willPerformRedirectRefusesLoopbackTarget() async {
        let guardDelegate = RemoteImageRedirectGuard()
        let response = HTTPURLResponse(
            url: URL(string: "https://allowlisted.example.com/avatar.png")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://127.0.0.1:9000/internal"]
        )!
        let newRequest = URLRequest(url: URL(string: "http://127.0.0.1:9000/internal")!)

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://allowlisted.example.com/avatar.png")!)
        defer { session.invalidateAndCancel() }

        let resolved: URLRequest? = await withCheckedContinuation { continuation in
            guardDelegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: newRequest
            ) { continuation.resume(returning: $0) }
        }
        #expect(resolved == nil)
    }

    /// A redirect to another allowlisted public HTTPS host is permitted and the
    /// original request is forwarded unchanged.
    @Test func willPerformRedirectAllowsPublicHttpsTarget() async {
        let guardDelegate = RemoteImageRedirectGuard()
        let response = HTTPURLResponse(
            url: URL(string: "https://cdn-a.example.com/avatar.png")!,
            statusCode: 301,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://cdn-b.example.com/avatar.png"]
        )!
        let newRequest = URLRequest(url: URL(string: "https://cdn-b.example.com/avatar.png")!)

        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://cdn-a.example.com/avatar.png")!)
        defer { session.invalidateAndCancel() }

        let resolved: URLRequest? = await withCheckedContinuation { continuation in
            guardDelegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: newRequest
            ) { continuation.resume(returning: $0) }
        }
        #expect(resolved?.url?.absoluteString == "https://cdn-b.example.com/avatar.png")
    }
}

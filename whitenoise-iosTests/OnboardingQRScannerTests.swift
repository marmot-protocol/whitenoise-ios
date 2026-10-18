import Testing
@testable import whitenoise_ios

@MainActor
struct OnboardingQRScannerTests {
    private let key = "nsec1j4c6269y9w0q2er2xjw8sv2ehyrtfxq3jwgdlxj6qfn8z4gjsq5qfvfk99"

    @Test func invalidScanWaitsForExplicitRetryBeforeAcceptingAnotherCode() {
        var accepted: [String] = []
        var rejected = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            validate: ImportIdentityView.isPlausibleNsec,
            onInvalidPayload: { rejected += 1 }
        )
        scanner.receive("nsec-not-a-valid-key")
        scanner.receive(key)
        scanner.resumeScanning(attempt: 0)
        scanner.receive(key)
        #expect(rejected == 1)
        #expect(accepted.isEmpty)
        scanner.resumeScanning(attempt: 1)
        scanner.receive(key)
        scanner.receive(key)
        #expect(accepted == [key])
    }

    @Test func defaultScannerStillAcceptsRawProfilePayloads() {
        var accepted: [String] = []
        let scanner = QRScannerView.Coordinator(onScan: { accepted.append($0) }, onError: { _ in })
        scanner.receive("nostr:profile-reference")
        #expect(accepted == ["nostr:profile-reference"])
    }
}

@MainActor
struct ContinuousQRScannerTests {
    private let profile = "marmot://profile/npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

    @Test func rejectsOncePerCodeAndAcceptsTheNextProfileWithoutRestarting() {
        var accepted: [String] = []
        var rejected = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            validate: { raw in
                if case .profile = DeepLink.parse(string: raw) { true } else { false }
            },
            onInvalidPayload: { rejected += 1 },
            continuesAfterInvalidPayload: true
        )

        for _ in 0..<10 { scanner.receive("https://example.com") }
        #expect(rejected == 1)
        #expect(accepted.isEmpty)
        scanner.receive("WIFI:T:WPA;S:Example;;")
        #expect(rejected == 2)
        scanner.receive(profile)
        scanner.receive(profile)
        #expect(accepted == [profile])
    }

    @Test func explicitRetryAllowsTheSameInvalidCodeToBeReportedAgain() {
        var rejected = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { _ in }, onError: { _ in }, validate: { _ in false },
            onInvalidPayload: { rejected += 1 },
            continuesAfterInvalidPayload: true
        )
        scanner.receive("invalid")
        scanner.receive("invalid")
        #expect(rejected == 1)
        scanner.resumeScanning(attempt: 1)
        scanner.receive("invalid")
        #expect(rejected == 2)
    }
}

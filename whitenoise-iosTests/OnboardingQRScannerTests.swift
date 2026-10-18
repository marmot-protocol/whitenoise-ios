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
        scanner.receiveFrame(["nsec-not-a-valid-key", key])
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

    @Test func rejectsOncePerFeedbackIntervalAndAcceptsTheNextProfileWithoutRestarting() {
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
        for _ in 0..<10 {
            scanner.receive("WIFI:T:WPA;S:Example;;")
            scanner.receive("https://example.com")
        }
        #expect(rejected == 1)
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

    @Test func returningToAStillVisibleProfileDoesNotOpenItAgain() {
        var accepted: [String] = []
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: profile
        )
        let start = ContinuousClock.now
        for step in 0..<10 {
            scanner.receiveFrame([profile], at: start.advanced(by: .milliseconds(step * 400)))
            scanner.resumeScanning(attempt: step)
        }
        #expect(accepted.isEmpty)
    }

    @Test func callbackPauseDoesNotRearmAStillVisibleProfile() {
        var accepted: [String] = []
        var cleared = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: profile,
            onPreviousPayloadCleared: { cleared += 1 }
        )
        let start = ContinuousClock.now
        scanner.receiveFrame([profile], at: start)
        scanner.receiveFrame([profile], at: start.advanced(by: .seconds(5)))
        scanner.receiveFrame([], at: start.advanced(by: .seconds(6)))
        scanner.receiveFrame([profile], at: start.advanced(by: .seconds(10)))
        #expect(accepted.isEmpty)
        #expect(cleared == 0)
    }

    @Test func previousProfileCanBeScannedAfterObservedAbsence() {
        var accepted: [String] = []
        var cleared = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: profile,
            onPreviousPayloadCleared: { cleared += 1 }
        )
        let start = ContinuousClock.now
        scanner.receiveFrame([profile], at: start)
        scanner.receiveFrame([], at: start.advanced(by: .milliseconds(100)))
        scanner.receiveFrame([profile], at: start.advanced(by: .milliseconds(200)))
        #expect(accepted.isEmpty)
        #expect(cleared == 0)

        scanner.receiveFrame([], at: start.advanced(by: .milliseconds(800)))
        scanner.receiveFrame([], at: start.advanced(by: .milliseconds(1300)))
        #expect(cleared == 0)
        scanner.receiveFrame([], at: start.advanced(by: .milliseconds(1900)))
        #expect(cleared == 1)
        scanner.receiveFrame([profile], at: start.advanced(by: .seconds(2)))
        #expect(cleared == 1)
        #expect(accepted == [profile])
    }

    @Test(arguments: [false, true])
    func validProfileBehindInvalidCodeOpensImmediately(alreadyRejected: Bool) {
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
        if alreadyRejected { scanner.receive("invalid") }
        scanner.receiveFrame(["invalid", profile])
        #expect(accepted == [profile])
        #expect(rejected == (alreadyRejected ? 1 : 0))
    }

    @Test func anotherCodeCanOpenWhileThePreviousCodeIsStillVisible() {
        var accepted: [String] = []
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: "previous-profile"
        )
        scanner.receiveFrame(["previous-profile", profile])
        #expect(accepted == [profile])
    }
}

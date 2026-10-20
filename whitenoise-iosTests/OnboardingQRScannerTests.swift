import Testing
import UIKit
import Vision
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

    @Test func holdingOrAlternatingInvalidCodesReportsOnceAndStillAcceptsAProfile() {
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

    @Test(arguments: [0, 900, 1000, 2000])
    func previousProfileReopensAfterOneSecondWithoutLeavingTheFrame(elapsedMilliseconds: Int) {
        var accepted: [String] = []
        let start = ContinuousClock.now
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: profile,
            at: start
        )
        scanner.receiveFrame([profile], at: start)
        scanner.receiveFrame([profile], at: start.advanced(by: .milliseconds(elapsedMilliseconds)))
        #expect(accepted == (elapsedMilliseconds >= 1000 ? [profile] : []))
    }

    @Test func eachReturnStartsAFreshCooldownAndRepeatedFramesDoNotExtendIt() {
        var accepted: [String] = []
        let start = ContinuousClock.now
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            continuesAfterInvalidPayload: true,
            at: start
        )
        scanner.receiveFrame([profile], at: start)
        for cycle in 1...2 {
            let returnedAt = start.advanced(by: .seconds(cycle * 10))
            scanner.setScanningEnabled(false, at: returnedAt.advanced(by: .seconds(-5)))
            scanner.receiveFrame([profile], at: returnedAt.advanced(by: .seconds(-1)))
            scanner.setScanningEnabled(true, at: returnedAt)
            for milliseconds in [0, 200, 400, 900] {
                scanner.receiveFrame([profile], at: returnedAt.advanced(by: .milliseconds(milliseconds)))
            }
            #expect(accepted.count == cycle)
            scanner.receiveFrame([profile], at: returnedAt.advanced(by: .seconds(1)))
            #expect(accepted == Array(repeating: profile, count: cycle + 1))
        }
    }

    @Test func invalidFeedbackClearsAfterObservedAbsenceAndCanBeReportedAgain() {
        var rejected = 0
        var cleared = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { _ in }, onError: { _ in }, validate: { _ in false },
            onInvalidPayload: { rejected += 1 },
            onInvalidPayloadCleared: { cleared += 1 },
            continuesAfterInvalidPayload: true
        )
        let start = ContinuousClock.now
        scanner.receiveFrame(["invalid"], at: start)
        // A transient missed detection must not rearm feedback or repeat the haptic.
        scanner.receiveFrame([], at: start.advanced(by: .milliseconds(200)))
        scanner.receiveFrame(["invalid"], at: start.advanced(by: .milliseconds(400)))
        scanner.receiveFrame(["invalid"], at: start.advanced(by: .seconds(10)))
        #expect(rejected == 1)
        #expect(cleared == 0)

        scanner.receiveFrame([], at: start.advanced(by: .seconds(11)))
        scanner.receiveFrame([], at: start.advanced(by: .seconds(12)))
        #expect(cleared == 1)
        scanner.receiveFrame(["invalid"], at: start.advanced(by: .seconds(13)))
        #expect(rejected == 2)
    }

    @Test func bufferedFramesFromBeforeReturningToConnectAreIgnored() {
        var accepted: [String] = []
        let scanner = QRScannerView.Coordinator(
            onScan: { accepted.append($0) }, onError: { _ in },
            previouslyScannedPayload: profile
        )
        let start = ContinuousClock.now
        scanner.setScanningEnabled(false, at: start)
        scanner.setScanningEnabled(true, at: start.advanced(by: .seconds(5)))
        scanner.receiveFrame(["another-profile"], at: start.advanced(by: .seconds(3)))
        scanner.receiveFrame([], at: start.advanced(by: .seconds(4)))
        scanner.receiveFrame([profile], at: start.advanced(by: .milliseconds(5500)))
        #expect(accepted.isEmpty)
    }

    @Test func decodedCameraImagesClearInvalidFeedbackWhenTheCodeLeaves() throws {
        let codeImage = try #require(QRCode.image(from: profile)?.cgImage)
        let blankImage = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 480)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
        }
        let code = try QRScannerFrameDetector.payloads(in: VNImageRequestHandler(cgImage: codeImage))
        let empty = try QRScannerFrameDetector.payloads(
            in: VNImageRequestHandler(cgImage: #require(blankImage.cgImage))
        )
        #expect(code == [profile])
        #expect(empty.isEmpty)

        var cleared = 0
        let scanner = QRScannerView.Coordinator(
            onScan: { _ in }, onError: { _ in }, validate: { _ in false },
            onInvalidPayloadCleared: { cleared += 1 },
            continuesAfterInvalidPayload: true
        )
        let start = ContinuousClock.now
        scanner.receiveFrame(code, at: start)
        scanner.receiveFrame(empty, at: start.advanced(by: .milliseconds(200)))
        scanner.receiveFrame(empty, at: start.advanced(by: .milliseconds(1400)))
        #expect(cleared == 1)
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

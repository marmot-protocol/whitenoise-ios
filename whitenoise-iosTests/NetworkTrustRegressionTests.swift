import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

struct NetworkTrustRegressionTests {
    @Test func nprofileResolutionStripsUnsafeRelayHintsBeforeMarmot() throws {
        let accountIdHex = hex("42")
        let raw = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: [
                "wss://relay.example/path",
                "ws://insecure.example",
                "wss://127.0.0.1/private",
                "wss://relay.example/path",
            ]
        ))

        let sanitized = try #require(NostrProfileReference.referenceForResolution(from: raw))
        #expect(NostrProfileReference.pubkeyHex(fromBech32: sanitized) == accountIdHex)
        #expect(sanitized == NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: ["wss://relay.example/path"]
        ))
    }

    @Test func nprofileEncodingNormalizesDeduplicatesAndCapsRelayHints() throws {
        let accountIdHex = hex("43")
        let normalizedRelays = (0..<8).map { "wss://relay\($0).example/path" }
        let encoded = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: [
                "ws://insecure.example",
                "WSS://RELAY0.EXAMPLE/path",
                normalizedRelays[0],
            ] + Array(normalizedRelays.dropFirst()) + ["wss://relay8.example/path"]
        ))
        let expected = try #require(NostrProfileReference.nprofile(
            fromAccountIdHex: accountIdHex,
            relayHints: normalizedRelays
        ))

        #expect(encoded == expected)
    }

    @Test func malformedPunycodeHostIsStillFlaggedAsInternationalized() throws {
        let url = try #require(URL(string: "https://xn--.example/path"))
        let display = MessageExternalLinkConfirmation.displayText(for: url)

        #expect(display.contains("IDN/punycode"))
    }

    @Test func notificationAvatarBytesRequireADecodableRasterImage() throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        #expect(NotificationCommunicationDecorator.isAllowedAvatarData(png))
        #expect(!NotificationCommunicationDecorator.isAllowedAvatarData(Data("not an image".utf8)))
        #expect(!NotificationCommunicationDecorator.isAllowedAvatarData(Data(
            "<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8
        )))
        #expect(NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 1_024, height: 1_024)]
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 4_097, height: 1)]
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: Array(repeating: (width: 1, height: 1), count: 9)
        ))
        #expect(!NotificationCommunicationDecorator.avatarMetadataIsAllowed(
            frameDimensions: [(width: 4_096, height: 4_096), (width: 1, height: 1)]
        ))
    }
}

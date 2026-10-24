import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct AppContainerConfigTests {

    @Test func seedRelaysUseWhiteNoiseRegionalRelaysOnly() {
        #expect(AppContainerConfig.seedRelays == [
            "wss://relay.eu.whitenoise.chat",
            "wss://relay.us.whitenoise.chat"
        ])
    }

    @Test func pushServerConfigMatchesBuildFlavor() throws {
        // The push server pubkey is flavor-specific (`WHITENOISE_PUSH_SERVER_PUBKEY_HEX`),
        // so assert against the value for the flavor this test bundle was built
        // with rather than hardcoding production; the test runs under Staging in CI.
        let config = try #require(NativePushServerConfig.current())

        let expectedPubkeyByFlavor = [
            "production": "73a4996bd18de19f6ac5f6ad42f5f2671eba6e5b739ea9695f07b00b0693fc04",
            "staging": "94186f72f66d09f94ca33599fda4b39cd8ac403769647658252dc48b8318f0c9"
        ]
        let flavor = try #require(Bundle.main.object(forInfoDictionaryKey: "WNFlavor") as? String)
        let expectedPubkey = try #require(expectedPubkeyByFlavor[flavor])

        #expect(config.serverPubkeyHex == expectedPubkey)
        #expect(config.relayHint == "wss://relay.eu.whitenoise.chat")
        #expect(config.relayHint == AppContainerConfig.pushNotificationRelayHint)
        #expect(AppContainerConfig.seedRelays.contains(config.relayHint ?? ""))
    }

    @Test func marmotRootUsesProductScopedCutoverDirectoryName() {
        let base = URL(fileURLWithPath: "/tmp/WhiteNoise-test", isDirectory: true)

        #expect(AppContainerConfig.productDirectoryName == "White Noise")
        #expect(AppContainerConfig.legacyMarmotDirectoryName == "Marmot")
        #expect(AppContainerConfig.marmotRoot(in: base).path == "/tmp/WhiteNoise-test/White Noise/Marmot")
    }

    @Test func productionRootThrowsWhenAppGroupContainerUnavailable() {
        // Marmot data must live only in the shared App Group container so the
        // app and the Notification Service Extension share one store. When the
        // container is missing we hard-fail rather than fork the store into a
        // per-process path.
        let fileManager = StubFileManager(
            sharedContainerURL: nil
        )

        #expect(throws: AppContainerError.appGroupContainerUnavailable) {
            _ = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)
        }
        #expect(fileManager.applicationSupportLookupCount == 0)
    }

    @Test func productionRootDoesNotConsultApplicationSupport() throws {
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotShared-\(UUID().uuidString)", isDirectory: true)
        let fileManager = StubFileManager(
            sharedContainerURL: shared
        )

        let root = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)

        let expectedRoot = shared
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)
        #expect(root.path == expectedRoot.path)
        #expect(fileManager.applicationSupportLookupCount == 0)
    }

    @Test func productionRootSurfacesDirectoryCreationFailure() {
        let shared = URL(fileURLWithPath: "/tmp/WhiteNoise-unwritable", isDirectory: true)
        let root = shared
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Marmot", isDirectory: true)
        let creationError = NSError(
            domain: "AppContainerConfigTests",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let fileManager = StubFileManager(
            sharedContainerURL: shared,
            createDirectoryError: creationError
        )

        #expect(throws: AppContainerError.storageDirectoryCreationFailed(
            path: root.path,
            reason: "permission denied"
        )) {
            _ = try AppContainerConfig.productionMarmotRoot(fileManager: fileManager)
        }
        #expect(fileManager.createdDirectories.map(\.path) == [root.path])
    }
}

/// Test double that lets us drive `AppContainerConfig`'s storage resolution
/// down its failure branches deterministically.
private final class StubFileManager: FileManager {
    private let sharedContainerURL: URL?
    private let createDirectoryError: Error?
    private(set) var applicationSupportLookupCount = 0
    private(set) var createdDirectories: [URL] = []

    init(
        sharedContainerURL: URL?,
        createDirectoryError: Error? = nil
    ) {
        self.sharedContainerURL = sharedContainerURL
        self.createDirectoryError = createDirectoryError
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        sharedContainerURL
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        if directory == .applicationSupportDirectory {
            applicationSupportLookupCount += 1
        }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }

    override func fileExists(atPath path: String) -> Bool {
        if createDirectoryError != nil { return false }
        return super.fileExists(atPath: path)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        createdDirectories.append(url)
        if let createDirectoryError {
            throw createDirectoryError
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }
}

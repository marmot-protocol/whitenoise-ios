import Testing
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Combine
import Synchronization
@testable import whitenoise_ios
@testable import MarmotKit

extension MarmotClient {
    static let unreachableTestRelays = ["wss://relay.invalid.test"]

    /// Builds a MarmotClient pointed at a unique temp directory so unit tests
    /// stay hermetic. Falls back to the production root only if the temp dir
    /// can't be created (which would itself be a test environment problem).
    static func testClient(relayUrls: [String] = unreachableTestRelays) throws -> MarmotClient {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try MarmotClient(rootPath: tmp.path, relayUrls: relayUrls)
    }
}

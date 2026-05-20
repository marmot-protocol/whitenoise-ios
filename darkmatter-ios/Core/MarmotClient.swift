import Foundation
import MarmotKit

/// Thin wrapper around the UniFFI-generated `Marmot` handle.
///
/// Centralizes the on-disk root path, default relay set, and the few places
/// the iOS app needs to make blocking-ish startup choices. Everything else
/// the app does goes through the underlying `Marmot` instance directly.
final class MarmotClient {

    /// Default Nostr relay set used for new identities until the user edits
    /// their relay configuration in Settings.
    static let defaultRelays: [String] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net"
    ]

    let marmot: Marmot
    let rootPath: String

    init() {
        let root = MarmotClient.applicationSupportRoot()
        self.rootPath = root
        self.marmot = Marmot(rootPath: root, relayUrls: MarmotClient.defaultRelays)
    }

    private static func applicationSupportRoot() -> String {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("Marmot", isDirectory: true)
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root.path
    }
}

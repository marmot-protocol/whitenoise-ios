import Foundation
import MarmotKit

/// Thin wrapper around the UniFFI-generated `Marmot` handle.
///
/// Centralizes the on-disk root path, bootstrap relay set, and the few places
/// the iOS app needs to make blocking-ish startup choices. Everything else
/// the app does goes through the underlying `Marmot` instance directly.
final class MarmotClient {

    /// Seed relays used to start the Rust relay plane and bootstrap new local
    /// identities. Per-account relay lists live in Marmot after setup.
    static let seedRelays: [String] = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net"
    ]

    let marmot: Marmot
    let rootPath: String

    convenience init() throws {
        let root = MarmotClient.applicationSupportRoot()
        try self.init(rootPath: root, relayUrls: Self.seedRelays)
    }

    /// Test-friendly init that lets callers override the on-disk root and
    /// relay set. Production code goes through the no-arg convenience init.
    /// Throwing because the keychain-backed account store can fail to
    /// initialize (account secrets are stored in the Keychain, not on disk).
    init(rootPath: String, relayUrls: [String]) throws {
        self.rootPath = rootPath
        self.marmot = try Marmot(rootPath: rootPath, relayUrls: relayUrls)
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

enum RelaySettings {
    static func editableRelays(from lists: AccountRelayListsFfi) -> [String] {
        normalizedRelayURLs(lists.defaultRelays.isEmpty ? lists.nip65.relays : lists.defaultRelays)
    }

    static func bootstrapRelays(from lists: AccountRelayListsFfi) -> [String] {
        for relays in [lists.bootstrapRelays, lists.defaultRelays, lists.nip65.relays] {
            let normalized = normalizedRelayURLs(relays)
            if !normalized.isEmpty { return normalized }
        }
        return MarmotClient.seedRelays
    }

    static func normalizedRelayURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = trimmed.lowercased()
        guard scheme.hasPrefix("wss://") || scheme.hasPrefix("ws://") else { return nil }
        return trimmed
    }

    static func normalizedRelayURLs(_ relays: [String]) -> [String] {
        var normalized: [String] = []
        for relay in relays {
            guard let url = normalizedRelayURL(relay), !normalized.contains(url) else { continue }
            normalized.append(url)
        }
        return normalized
    }
}

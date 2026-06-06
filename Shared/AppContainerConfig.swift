import Foundation

enum AppContainerConfig {
    static let appGroupIdentifier = "group.dev.ipf.darkmatter"
    static let marmotDirectoryName = "Marmot"
    static let seedRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.us.whitenoise.chat",
        "wss://relay.eu.whitenoise.chat"
    ]

    static func marmotRoot(in baseURL: URL) -> URL {
        baseURL.appendingPathComponent(marmotDirectoryName, isDirectory: true)
    }

    static func applicationSupportBase(fileManager: FileManager = .default) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func sharedBase(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func productionMarmotRoot(fileManager: FileManager = .default) -> URL {
        let fallbackBase = applicationSupportBase(fileManager: fileManager)
        let legacyRoot = marmotRoot(in: fallbackBase)
        guard let sharedBase = sharedBase(fileManager: fileManager) else {
            ensureDirectoryExists(legacyRoot, fileManager: fileManager)
            return legacyRoot
        }

        let sharedRoot = marmotRoot(in: sharedBase)
        migrateLegacyRootIfNeeded(from: legacyRoot, to: sharedRoot, fileManager: fileManager)
        ensureDirectoryExists(sharedRoot, fileManager: fileManager)
        return sharedRoot
    }

    static func migrateLegacyRootIfNeeded(from legacyRoot: URL, to sharedRoot: URL, fileManager: FileManager = .default) {
        guard legacyRoot.path != sharedRoot.path,
              fileManager.fileExists(atPath: legacyRoot.path),
              !fileManager.fileExists(atPath: sharedRoot.path)
        else { return }

        ensureDirectoryExists(sharedRoot.deletingLastPathComponent(), fileManager: fileManager)
        try? fileManager.moveItem(at: legacyRoot, to: sharedRoot)
    }

    static func ensureDirectoryExists(_ url: URL, fileManager: FileManager = .default) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct NativePushServerConfig: Equatable {
    static let serverPubkeyInfoKey = "DarkmatterPushServerPubkeyHex"
    static let relayHintInfoKey = "DarkmatterPushRelayHint"

    let serverPubkeyHex: String
    let relayHint: String?

    static func current(bundle: Bundle = .main) -> NativePushServerConfig? {
        guard let rawPubkey = bundle.object(forInfoDictionaryKey: serverPubkeyInfoKey) as? String else {
            return nil
        }
        let pubkey = rawPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pubkey.isEmpty else { return nil }

        let rawRelayHint = bundle.object(forInfoDictionaryKey: relayHintInfoKey) as? String
        let relayHint = rawRelayHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return NativePushServerConfig(serverPubkeyHex: pubkey, relayHint: relayHint)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

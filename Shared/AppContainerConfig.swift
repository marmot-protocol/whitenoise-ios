import Foundation

/// Failures resolving the on-disk location for the Marmot store.
enum AppContainerError: Error, LocalizedError, Equatable {
    /// The shared App Group container could not be resolved. Marmot data must
    /// live in a single location shared by the app and its extensions, so we
    /// refuse to run rather than fork the store into a per-process path.
    case appGroupContainerUnavailable

    var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable:
            return "The shared App Group container (\(AppContainerConfig.appGroupIdentifier)) is unavailable, so Marmot storage cannot be opened safely."
        }
    }
}

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

    static func sharedBase(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Resolves the on-disk root for the production Marmot store.
    ///
    /// The Marmot root lives only in the shared App Group container so the main
    /// app and the Notification Service Extension read and write one store. If
    /// that container is unavailable we throw rather than fall back to a
    /// per-process location: a second path would silently fork runtime data
    /// between the app and the extension. The caller surfaces a hard failure.
    static func productionMarmotRoot(fileManager: FileManager = .default) throws -> URL {
        guard let sharedBase = sharedBase(fileManager: fileManager) else {
            throw AppContainerError.appGroupContainerUnavailable
        }

        let sharedRoot = marmotRoot(in: sharedBase)
        ensureDirectoryExists(sharedRoot, fileManager: fileManager)
        return sharedRoot
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

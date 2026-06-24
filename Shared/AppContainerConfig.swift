import Foundation

/// Failures resolving the on-disk location for the Marmot store.
nonisolated enum AppContainerError: Error, LocalizedError, Equatable {
    /// The shared App Group container could not be resolved. Marmot data must
    /// live in a single location shared by the app and its extensions, so we
    /// refuse to run rather than fork the store into a per-process path.
    case appGroupContainerUnavailable
    case storageDirectoryCreationFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable:
            return "The shared App Group container (\(AppContainerConfig.appGroupIdentifier)) is unavailable, so Marmot storage cannot be opened safely."
        case .storageDirectoryCreationFailed(let path, let reason):
            return "Could not create Marmot storage directory at \(path): \(reason)"
        }
    }
}

nonisolated enum AppContainerConfig {
    /// The App Group is flavor-specific (production vs. staging) and both the
    /// app and the NSE link this file, so it can't be a compile-time constant.
    /// Each target's Info.plist carries `AppGroupIdentifier` = `$(APP_GROUP_IDENTIFIER)`
    /// from its flavor xcconfig. A missing value means a build misconfiguration;
    /// fail hard rather than silently fall back to the production group, which
    /// would fork a staging build's data into the wrong container.
    static let appGroupIdentifier: String = {
        guard let identifier = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
            .flatMap({ $0.isEmpty ? nil : $0 }) else {
            fatalError("AppGroupIdentifier is missing from Info.plist; cannot resolve the shared App Group container.")
        }
        return identifier
    }()
    static let marmotDirectoryName = "Marmot"
    static let seedRelays = [
        "wss://relay.eu.whitenoise.chat",
        "wss://relay.us.whitenoise.chat"
    ]

    /// MIP-05 notification-server inbox relay stamped into push registrations.
    /// Kind-446 triggers publish here; keep aligned with `seedRelays`.
    static let pushNotificationRelayHint = seedRelays[0]

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
        try ensureDirectoryExists(sharedRoot, fileManager: fileManager)
        return sharedRoot
    }

    static func ensureDirectoryExists(_ url: URL, fileManager: FileManager = .default) throws {
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                throw AppContainerError.storageDirectoryCreationFailed(
                    path: url.path,
                    reason: error.localizedDescription
                )
            }
        }
    }
}

nonisolated struct NativePushServerConfig: Equatable {
    static let serverPubkeyInfoKey = "DarkmatterPushServerPubkeyHex"
    static let relayHintInfoKey = "DarkmatterPushRelayHint"

    let serverPubkeyHex: String
    let relayHint: String?

    static func current(bundle: Bundle = .main) -> NativePushServerConfig? {
        current(
            rawPubkey: bundle.object(forInfoDictionaryKey: serverPubkeyInfoKey) as? String,
            rawRelayHint: bundle.object(forInfoDictionaryKey: relayHintInfoKey) as? String
        )
    }

    static func current(rawPubkey: String?, rawRelayHint: String?) -> NativePushServerConfig? {
        // The push server pubkey must be a 32-byte (64-char) hex string. A
        // misconfigured build previously passed the raw value straight through
        // and only failed deep inside push registration (issue #72); reject it
        // here so the app cleanly behaves as if push were unconfigured.
        guard let pubkey = Hex.normalized32Bytes(rawPubkey) else { return nil }

        let relayHint = rawRelayHint.flatMap(RelayURL.normalized)

        return NativePushServerConfig(serverPubkeyHex: pubkey, relayHint: relayHint)
    }
}

nonisolated enum RelayURL {
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws",
              let host = components.host,
              !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.host = host.lowercased()
        return components.url?.absoluteString
    }
}

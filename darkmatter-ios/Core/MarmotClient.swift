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
    static let seedRelays = AppContainerConfig.seedRelays

    let marmot: Marmot
    let rootPath: String
    let relayUrls: [String]
    let telemetryConfig: TelemetryBuildConfig

    convenience init() throws {
        try self.init(rootPath: AppContainerConfig.productionMarmotRoot().path, relayUrls: Self.seedRelays)
    }

    /// Test-friendly init that lets callers override the on-disk root and
    /// relay set. Production code goes through the no-arg convenience init.
    /// Throwing because the keychain-backed account store can fail to
    /// initialize (account secrets are stored in the Keychain, not on disk).
    init(rootPath: String, relayUrls: [String]) throws {
        self.rootPath = rootPath
        self.relayUrls = relayUrls
        self.telemetryConfig = TelemetryBuildConfig.current()
        self.marmot = try Marmot(rootPath: rootPath, relayUrls: relayUrls)
        try configureTelemetryRuntime()
    }

    func freshRuntime() throws -> MarmotClient {
        try MarmotClient(rootPath: rootPath, relayUrls: relayUrls)
    }

    private func configureTelemetryRuntime() throws {
        let installId = try marmot.telemetryInstallId()
        try marmot.setRelayTelemetryRuntimeConfig(
            config: telemetryConfig.runtimeConfig(installId: installId)
        )
    }
}

protocol AccountRelayListManaging {
    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi
    func setAccountInboxRelays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi
    func setAccountNip65Relays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi
}

extension Marmot: AccountRelayListManaging {}

struct RelaySettingsSaveFailure: LocalizedError {
    let underlyingError: Error
    let reloadedLists: AccountRelayListsFfi?

    var errorDescription: String? {
        underlyingError.localizedDescription
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

    static func normalizedRelayURLs(_ relays: [String]) -> [String] {
        var normalized: [String] = []
        for relay in relays {
            guard let url = normalizedRelayURL(relay), !normalized.contains(url) else { continue }
            normalized.append(url)
        }
        return normalized
    }

    static func saveAccountRelays(
        accountRef: String,
        relays: [String],
        currentLists: AccountRelayListsFfi?,
        manager: AccountRelayListManaging
    ) async throws -> AccountRelayListsFfi {
        let normalized = normalizedRelayURLs(relays)
        let bootstrap = currentLists.map(bootstrapRelays(from:)) ?? MarmotClient.seedRelays

        do {
            _ = try await manager.setAccountInboxRelays(
                accountRef: accountRef,
                relays: normalized,
                bootstrapRelays: bootstrap
            )
            return try await manager.setAccountNip65Relays(
                accountRef: accountRef,
                relays: normalized,
                bootstrapRelays: bootstrap
            )
        } catch {
            let reloadedLists = try? manager.accountRelayLists(accountRef: accountRef)
            throw RelaySettingsSaveFailure(
                underlyingError: error,
                reloadedLists: reloadedLists
            )
        }
    }
}

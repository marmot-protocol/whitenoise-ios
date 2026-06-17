import Foundation
import MarmotKit

struct TimelineReadMarkResult {
    let messageIdHex: String
    let row: ChatListRowFfi?
    let succeeded: Bool
}

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
        try configureAuditLogTracker()
    }

    func freshRuntime() throws -> MarmotClient {
        try MarmotClient(rootPath: rootPath, relayUrls: relayUrls)
    }

    /// Lists local accounts off the main actor. `Marmot.listAccounts()` is a
    /// synchronous FFI call that reads Keychain/storage, so running it inline on
    /// MainActor would block the UI. Encapsulating the offload here lets call
    /// sites read as a plain `await` instead of an unexplained `Task.detached`
    /// (#51).
    func listAccounts() async throws -> [AccountSummaryFfi] {
        try await Task.detached { [marmot] in
            try marmot.listAccounts()
        }.value
    }

    /// Normalizes a staged recipient reference off the main actor.
    /// `Marmot.normalizeMemberRef` is a synchronous FFI call (bech32/TLV decode
    /// plus possible relay-hint normalization), so running it inline on the
    /// MainActor blocks the UI on every add / QR scan / submit. Offloading it
    /// here lets the add-members / new-chat paths read as a plain `await` and
    /// only hop back to the MainActor to stage the result (#260).
    func normalizeMemberRef(memberRef: String) async throws -> MemberRefFfi {
        try await Task.detached(priority: .userInitiated) { [marmot, memberRef] in
            try marmot.normalizeMemberRef(memberRef: memberRef)
        }.value
    }

    /// Reads notification settings off the main actor before deciding which
    /// local accounts should refresh native push registration.
    func nativePushEnabledAccountRefs(accountRefs: [String]) async -> [String] {
        await Task.detached(priority: .utility) { [marmot, accountRefs] in
            NativePushRegistrationPolicy.enabledAccountRefs(accountRefs: accountRefs) { accountRef in
                try? marmot.notificationSettings(accountRef: accountRef)
            }
        }.value
    }

    /// Reads the local-notification preference off the main actor. Presentation
    /// should fail open if storage is temporarily unavailable.
    func localNotificationsEnabledForPresentation(accountRef: String) async -> Bool {
        await Task.detached(priority: .utility) { [marmot, accountRef] in
            do {
                return try marmot.notificationSettings(accountRef: accountRef).localNotificationsEnabled
            } catch {
                return true
            }
        }.value
    }

    func relayTelemetrySettings() async throws -> RelayTelemetrySettingsFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.relayTelemetrySettings()
        }.value
    }

    func auditLogSettings() async throws -> AuditLogSettingsFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.auditLogSettings()
        }.value
    }

    func auditLogFiles() async throws -> [AuditLogFileFfi] {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.auditLogFiles()
        }.value
    }

    func auditFileRows() async throws -> [AuditFileRow] {
        try await Task.detached(priority: .utility) { [marmot] in
            AuditFileRowProjection.rows(from: try marmot.auditLogFiles())
        }.value
    }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection {
        try await Task.detached(priority: .utility) { [marmot] in
            try PrivacySecuritySettingsProjection(
                telemetrySettings: marmot.relayTelemetrySettings(),
                auditSettings: marmot.auditLogSettings(),
                auditFiles: marmot.auditLogFiles()
            )
        }.value
    }

    func markTimelineMessagesRead(
        accountRef: String,
        groupIdHex: String,
        messageIdHexes: [String]
    ) async -> [TimelineReadMarkResult] {
        await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex, messageIdHexes] in
            messageIdHexes.map { messageIdHex in
                do {
                    let row = try marmot.markTimelineMessageRead(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex,
                        messageIdHex: messageIdHex
                    )
                    return TimelineReadMarkResult(messageIdHex: messageIdHex, row: row, succeeded: true)
                } catch {
                    return TimelineReadMarkResult(messageIdHex: messageIdHex, row: nil, succeeded: false)
                }
            }
        }.value
    }

    func initializeChatReadState(
        accountRef: String,
        groupIdHex: String
    ) async throws -> ChatListRowFfi? {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex] in
            try marmot.initializeChatReadState(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        }.value
    }

    func timelineMessages(
        accountRef: String,
        query: TimelineMessageQueryFfi
    ) async throws -> TimelinePageFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef, query] in
            try marmot.timelineMessages(accountRef: accountRef, query: query)
        }.value
    }

    func exportConversationTranscript(
        accountRef: String,
        group: AppGroupRecordFfi
    ) async throws -> URL {
        try await Task.detached(priority: .utility) { [marmot, accountRef, group] in
            let messages = try ConversationTranscriptExport.fetchAllMessages(
                marmot: marmot,
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            try Task.checkCancellation()
            let document = ConversationTranscriptExport.makeDocument(group: group, messages: messages)
            let data = try ConversationTranscriptExport.encodeJSON(document)
            return try ConversationTranscriptExport.writeTemporaryFile(
                data: data,
                groupIdHex: group.groupIdHex
            )
        }.value
    }

    func listMedia(
        accountRef: String,
        groupIdHex: String,
        limit: UInt32
    ) async throws -> [MediaRecordFfi] {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex, limit] in
            try marmot.listMedia(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                limit: limit
            )
        }.value
    }

    /// Reads profile/display-name projections off the main actor so SwiftUI row
    /// rendering can consume an app-owned cache instead of synchronously
    /// touching Marmot storage.
    func profileProjections(for requests: [ProfileProjectionRequest]) async -> [String: ProfileDisplayProjection] {
        await Self.profileProjections(for: requests, marmot: marmot)
    }

    static func profileProjections(
        for requests: [ProfileProjectionRequest],
        marmot: Marmot
    ) async -> [String: ProfileDisplayProjection] {
        await Task.detached(priority: .utility) {
            var projections: [String: ProfileDisplayProjection] = [:]
            for request in requests {
                projections[request.accountIdHex] = ProfileDisplayProjection(
                    profile: (try? marmot.userProfile(accountIdHex: request.accountIdHex)) ?? nil,
                    projectedName: marmot.displayName(accountIdHex: request.accountIdHex),
                    localAccountLabel: request.localAccountLabel
                )
            }
            return projections
        }.value
    }

    func startRuntime() async throws {
        try await configureTelemetryRuntime()
        try await marmot.start()
    }

    func configureTelemetryRuntime() async throws {
        let installId = try marmot.telemetryInstallId()
        try await marmot.setRelayTelemetryRuntimeConfig(
            config: telemetryConfig.runtimeConfig(installId: installId)
        )
    }

    private func configureAuditLogTracker() throws {
        _ = try marmot.setAuditLogTrackerConfig(
            config: telemetryConfig.auditTrackerConfig()
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
        RelayURL.normalized(raw)
    }

    static func normalizedRelayURLs(_ relays: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for relay in relays {
            guard let url = normalizedRelayURL(relay), seen.insert(url).inserted else { continue }
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

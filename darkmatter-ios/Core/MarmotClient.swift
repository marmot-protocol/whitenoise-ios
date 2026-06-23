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

    /// Reads the durable chat-list projection off the main actor. Chat-list
    /// screens call this on account bind and pull-to-refresh, and the generated
    /// `Marmot.chatList` binding is a synchronous storage read.
    func chatList(
        accountRef: String,
        includeArchived: Bool
    ) async throws -> [ChatListRowFfi] {
        try await Task.detached(priority: .utility) { [marmot, accountRef, includeArchived] in
            try marmot.chatList(accountRef: accountRef, includeArchived: includeArchived)
        }.value
    }

    /// Reads the per-account unread aggregate off the main actor. The generated
    /// `Marmot.accountUnreadSummary` binding is a synchronous storage aggregate
    /// over each account's materialized chat-list projection.
    func accountUnreadSummary() async throws -> [AccountUnreadFfi] {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.accountUnreadSummary()
        }.value
    }

    /// Reads published account relay-list projections off the main actor.
    /// `Marmot.accountRelayLists` is synchronous FFI backed by local storage, so
    /// MainActor-bound settings screens should await this wrapper.
    func accountRelayLists(accountRef: String) async throws -> AccountRelayListsFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef] in
            try marmot.accountRelayLists(accountRef: accountRef)
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

    /// Normalizes a scanned or deep-linked public-key reference off the main
    /// actor. `Marmot.accountIdHex` is synchronous FFI, so profile presentation
    /// must await this wrapper instead of decoding attacker-influenced input on
    /// the MainActor (#297).
    func accountIdHex(reference: String) async -> String? {
        await Task.detached(priority: .userInitiated) { [marmot, reference] in
            marmot.accountIdHex(reference: reference)
        }.value
    }

    /// Parses markdown off the main actor. `Marmot.parseMarkdown(text:)` is a
    /// synchronous `rustCall()` binding whose cost scales with message length,
    /// so running it inline on MainActor stalls the composer/send animation for
    /// long messages. Offloading here keeps the send path's optimistic-record
    /// build off the UI thread (#226).
    func parseMarkdown(text: String) async -> MarkdownDocumentFfi {
        await Task.detached(priority: .userInitiated) { [marmot] in
            marmot.parseMarkdown(text: text)
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

    /// Reads notification settings off the main actor. The generated Marmot
    /// binding is synchronous storage FFI, so settings screens should await this
    /// wrapper instead of touching the handle on MainActor.
    func notificationSettings(accountRef: String) async throws -> NotificationSettingsFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef] in
            try marmot.notificationSettings(accountRef: accountRef)
        }.value
    }

    /// Reads the native-push registration off the main actor. The generated
    /// Marmot binding is synchronous storage FFI.
    func pushRegistration(accountRef: String) async throws -> PushRegistrationFfi? {
        try await Task.detached(priority: .utility) { [marmot, accountRef] in
            try marmot.pushRegistration(accountRef: accountRef)
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

    /// Reveals the account's raw `nsec1…` backup off the main actor. Logged to
    /// the per-account audit log and marks the key as handled insecurely.
    func revealNsec(accountRef: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [marmot, accountRef] in
            try marmot.revealNsec(accountRef: accountRef)
        }.value
    }

    /// Exports a NIP-49 `ncryptsec1…` backup off the main actor. The Rust
    /// boundary zeroes the passphrase copy; the export is audit-logged without
    /// downgrading key-security metadata.
    func exportEncryptedSecretKey(accountRef: String, passphrase: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [marmot, accountRef, passphrase] in
            try marmot.exportEncryptedSecretKey(accountRef: accountRef, passphrase: passphrase)
        }.value
    }

    /// Destructive sign-out: leave MLS groups, delete relay KeyPackages, and
    /// wipe all local account state. Returns per-stage outcomes for UI.
    func signOutAndWipe(accountRef: String) async throws -> WipeOutcomeFfi {
        try await marmot.signOutAndWipe(accountRef: accountRef)
    }

    /// Reactivates a locally signed-out account without re-importing keys.
    func signInAccount(accountRef: String) async throws -> AccountSummaryFfi {
        try await marmot.signInAccount(accountRef: accountRef)
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

    /// Materializes a live chat-list subscription snapshot off the main actor.
    /// `ChatListSubscription.snapshot()` is a synchronous UniFFI call that can
    /// touch local Marmot storage while building the initial projected rows.
    func chatListSubscriptionSnapshot(
        _ subscription: ChatListSubscription
    ) async -> [ChatListRowFfi] {
        await Task.detached(priority: .utility) { [subscription] in
            subscription.snapshot()
        }.value
    }

    /// Materializes a live timeline subscription snapshot off the main actor.
    /// `TimelineMessagesSubscription.snapshot()` is a synchronous UniFFI call,
    /// so callers on MainActor must await this wrapper before applying the page.
    func timelineSubscriptionSnapshot(
        _ subscription: TimelineMessagesSubscription
    ) async -> TimelinePageFfi? {
        await Task.detached(priority: .utility) { [subscription] in
            subscription.snapshot()
        }.value
    }

    /// Materializes a live group-state subscription snapshot off the main actor.
    /// `GroupStateSubscription.snapshot()` is synchronous and may touch Marmot
    /// storage while building the current group record.
    func groupStateSubscriptionSnapshot(
        _ subscription: GroupStateSubscription
    ) async -> AppGroupRecordFfi? {
        await Task.detached(priority: .utility) { [subscription] in
            subscription.snapshot()
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

    // MARK: - Group mutations & reads

    /// Group/message mutation and read wrappers. The generated `Marmot`
    /// bindings are already `async throws` (they suspend, not block), so these
    /// forward directly — no `Task.detached` — exactly like `signOutAndWipe`.
    /// Routing them here keeps the raw handle out of feature code (the one
    /// seam).
    func createGroup(accountRef: String, name: String, memberRefs: [String], description: String?) async throws -> String {
        try await marmot.createGroup(accountRef: accountRef, name: name, memberRefs: memberRefs, description: description)
    }

    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        try await marmot.setGroupArchived(accountRef: accountRef, groupIdHex: groupIdHex, archived: archived)
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
    }

    func replyToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.replyToMessage(accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: targetMessageId, text: text)
    }

    func uploadMedia(accountRef: String, groupIdHex: String, request: MediaUploadRequestFfi) async throws -> MediaUploadResultFfi {
        try await marmot.uploadMedia(accountRef: accountRef, groupIdHex: groupIdHex, request: request)
    }

    func downloadMedia(accountRef: String, groupIdHex: String, reference: MediaAttachmentReferenceFfi) async throws -> MediaDownloadResultFfi {
        try await marmot.downloadMedia(accountRef: accountRef, groupIdHex: groupIdHex, reference: reference)
    }

    func inviteMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws -> GroupMutationResultFfi {
        try await marmot.inviteMembersDetailed(accountRef: accountRef, groupIdHex: groupIdHex, memberRefs: memberRefs)
    }

    func removeMembersDetailed(accountRef: String, groupIdHex: String, memberRefs: [String]) async throws -> GroupMutationResultFfi {
        try await marmot.removeMembersDetailed(accountRef: accountRef, groupIdHex: groupIdHex, memberRefs: memberRefs)
    }

    func promoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws -> GroupMutationResultFfi {
        try await marmot.promoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex, memberRef: memberRef)
    }

    func demoteAdminDetailed(accountRef: String, groupIdHex: String, memberRef: String) async throws -> GroupMutationResultFfi {
        try await marmot.demoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex, memberRef: memberRef)
    }

    func selfDemoteAdminDetailed(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi {
        try await marmot.selfDemoteAdminDetailed(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws -> SendSummaryFfi {
        try await marmot.updateGroupProfile(accountRef: accountRef, groupIdHex: groupIdHex, name: name, description: description)
    }

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?) async throws -> SendSummaryFfi {
        try await marmot.updateGroupAvatarUrl(accountRef: accountRef, groupIdHex: groupIdHex, url: url, dim: dim, thumbhash: thumbhash)
    }

    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.leaveGroup(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupMembers(accountRef: String, groupIdHex: String) async throws -> [AppGroupMemberRecordFfi] {
        try await marmot.groupMembers(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        try await marmot.groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi {
        try await marmot.groupManagementState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupMlsState(accountRef: String, groupIdHex: String) async throws -> AppGroupMlsStateFfi {
        try await marmot.groupMlsState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupPushDebugInfo(accountRef: String, groupIdHex: String) async throws -> GroupPushDebugInfoFfi {
        try await marmot.groupPushDebugInfo(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        try await marmot.deleteMessage(accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: targetMessageId)
    }

    func reactToMessage(accountRef: String, groupIdHex: String, targetMessageId: String, emoji: String) async throws -> SendSummaryFfi {
        try await marmot.reactToMessage(accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: targetMessageId, emoji: emoji)
    }

    func unreactFromMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        try await marmot.unreactFromMessage(accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: targetMessageId)
    }

    // MARK: - Profile & key packages

    /// Profile and key-package wrappers. The generated bindings are already
    /// `async throws`, so these forward directly without `Task.detached`.
    func publishUserProfile(accountRef: String, profile: UserProfileMetadataFfi, defaultRelays: [String], bootstrapRelays: [String]) async throws -> UserProfileMetadataFfi {
        try await marmot.publishUserProfile(accountRef: accountRef, profile: profile, defaultRelays: defaultRelays, bootstrapRelays: bootstrapRelays)
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        try await marmot.refreshProfile(accountIdHex: accountIdHex, relays: relays)
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        try await marmot.accountKeyPackages(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
    }

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        try await marmot.publishNewKeyPackage(accountRef: accountRef)
    }

    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64 {
        try await marmot.deleteAccountKeyPackage(accountRef: accountRef, eventIdHex: eventIdHex, relays: relays)
    }

    /// Bech32-encodes an account id. `Marmot.npub` is a trivial synchronous
    /// encode (microseconds, no I/O), so this stays a plain forwarder per the
    /// thin-shell plan — making it `async` would push churn into sync call
    /// sites for no benefit.
    func npub(accountIdHex: String) -> String? {
        marmot.npub(accountIdHex: accountIdHex)
    }

    // MARK: - Subscriptions

    /// Subscription factories. Routing them through `MarmotClient` keeps the raw
    /// `Marmot` handle from escaping to feature code; the returned subscription
    /// handles are the live channel.
    func subscribeEvents() -> EventsSubscription {
        marmot.subscribeEvents()
    }

    func subscribeChatList(accountRef: String, includeArchived: Bool) async throws -> ChatListSubscription {
        try await marmot.subscribeChatList(accountRef: accountRef, includeArchived: includeArchived)
    }

    func subscribeTimelineMessages(accountRef: String, groupIdHex: String?, limit: UInt32?) async throws -> TimelineMessagesSubscription {
        try await marmot.subscribeTimelineMessages(accountRef: accountRef, groupIdHex: groupIdHex, limit: limit)
    }

    func subscribeGroupState(accountRef: String, groupIdHex: String) async throws -> GroupStateSubscription {
        try await marmot.subscribeGroupState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func watchAgentTextStream(accountRef: String, groupIdHex: String, streamIdHex: String?, serverCertDer: Data?, insecureLocal: Bool) async throws -> AgentStreamSubscription {
        try await marmot.watchAgentTextStream(accountRef: accountRef, groupIdHex: groupIdHex, streamIdHex: streamIdHex, serverCertDer: serverCertDer, insecureLocal: insecureLocal)
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

/// Lets `RelaysViewModel` pass `manager: client` so the relay-save path never
/// touches the raw `Marmot` handle. The protocol's `accountRelayLists` is the
/// synchronous `throws` variant used inside `RelaySettings.saveAccountRelays`'
/// error-recovery reload; it is distinct from `MarmotClient`'s `async throws`
/// read wrapper. The two setters forward directly (already `async throws`).
extension MarmotClient: AccountRelayListManaging {
    func accountRelayLists(accountRef: String) throws -> AccountRelayListsFfi {
        try marmot.accountRelayLists(accountRef: accountRef)
    }

    func setAccountInboxRelays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        try await marmot.setAccountInboxRelays(accountRef: accountRef, relays: relays, bootstrapRelays: bootstrapRelays)
    }

    func setAccountNip65Relays(
        accountRef: String,
        relays: [String],
        bootstrapRelays: [String]
    ) async throws -> AccountRelayListsFfi {
        try await marmot.setAccountNip65Relays(accountRef: accountRef, relays: relays, bootstrapRelays: bootstrapRelays)
    }
}

struct RelaySettingsSaveFailure: LocalizedError {
    let underlyingError: Error
    let reloadedLists: AccountRelayListsFfi?

    var errorDescription: String? {
        underlyingError.localizedDescription
    }
}

enum RelaySettings {
    /// Shown for a published list whose relays are empty, or whose every entry
    /// sanitized entirely away (e.g. relays made only of control/bidi
    /// characters) — never a blank disclosure row.
    static let notPublishedMessage = L10n.string("Not published")

    static func editableRelays(from lists: AccountRelayListsFfi) -> [String] {
        normalizedRelayURLs(lists.defaultRelays.isEmpty ? lists.nip65.relays : lists.defaultRelays)
    }

    /// Published-list relay URLs (NIP-65 / kind:10050 inbox) come from
    /// `AccountRelayListsFfi`, parsed from relay-hosted events, and are
    /// therefore relay-influenced display strings. Render them through the
    /// relay/URL display boundary sanitizer so RTL-override / zero-width /
    /// invisible-format characters can't spoof the displayed host
    /// (Trojan-Source-style, #298 / #306 / #365), matching the defense
    /// `KeyPackagesView.sanitizedRelays` and `GroupRelaysPresentation.rows`
    /// already apply. Returns `[notPublishedMessage]` for the empty / fully
    /// sanitized-away case.
    static func publishedRelayRows(_ relays: [String]) -> [String] {
        guard !relays.isEmpty else { return [notPublishedMessage] }
        let sanitized = relays.compactMap { ProfileSanitizer.relayDisplayLine($0, maxLength: 120) }
        return sanitized.isEmpty ? [notPublishedMessage] : sanitized
    }

    /// Sanitized form of `AccountRelayListsFfi.missing`, the relay-influenced
    /// list of relay kinds/URLs not yet published, before it is joined into the
    /// "Missing: …" footer. Same display-boundary hardening as
    /// `publishedRelayRows`; entries that sanitize away are dropped.
    static func missingRelayLabels(_ missing: [String]) -> [String] {
        missing.compactMap { ProfileSanitizer.relayDisplayLine($0, maxLength: 120) }
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

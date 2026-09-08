import Foundation
import OSLog
@preconcurrency import MarmotKit

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
nonisolated final class MarmotClient: Sendable {
    private static let coldBootstrapLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "cold-bootstrap"
    )

    /// Seed relays used to start the Rust relay plane and bootstrap new local
    /// identities. Per-account relay lists live in Marmot after setup.
    static let seedRelays = AppContainerConfig.seedRelays

    let marmot: Marmot
    let rootPath: String
    let relayUrls: [String]
    /// Durable transport-cursor policy this runtime was constructed with.
    let cursorPersistence: CursorPersistenceFfi
    let productConfig: ProductAnalyticsBuildConfig
    let telemetryConfig: TelemetryBuildConfig

    convenience init() throws {
        try self.init(rootPath: AppContainerConfig.productionMarmotRoot().path, relayUrls: Self.seedRelays)
    }

    /// Designated init that lets callers override the on-disk root, relay set,
    /// and cursor policy. The app's durable runtime is constructed by the
    /// lifecycle coordinator with `.advance`; short-lived background passes
    /// use `.frozen` so they cannot ratchet the durable transport-cursor floor.
    /// Throwing because the keychain-backed account store can fail to
    /// initialize (account secrets are stored in the Keychain, not on disk).
    convenience init(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi = .advance
    ) throws {
        try self.init(
            rootPath: rootPath,
            relayUrls: relayUrls,
            cursorPersistence: cursorPersistence,
            telemetryConfig: TelemetryBuildConfig.current()
        )
    }

    init(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi,
        telemetryConfig: TelemetryBuildConfig
    ) throws {
        let constructionStartedAt = ContinuousClock.now
        self.rootPath = rootPath
        self.relayUrls = relayUrls
        self.cursorPersistence = cursorPersistence
        self.telemetryConfig = telemetryConfig
        self.productConfig = .current()
        self.marmot = try Marmot.newWithCursorPersistence(
            rootPath: rootPath,
            relayUrls: relayUrls,
            cursorPersistence: cursorPersistence
        )
        _ = try marmot.setAuditLogTrackerConfig(
            config: telemetryConfig.auditTrackerConfig()
        )
        Self.coldBootstrapLog.info(
            "runtime_constructed duration_ms=\(Self.elapsedMilliseconds(since: constructionStartedAt), format: .fixed(precision: 0), privacy: .public)"
        )
    }

    func freshRuntime() throws -> MarmotClient {
        try MarmotClient(rootPath: rootPath, relayUrls: relayUrls, cursorPersistence: cursorPersistence)
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

    func onboardingSnapshot(accountID: String) async throws -> OnboardingSnapshotFfi? {
        try await Task.detached { [marmot] in
            try marmot.onboardingSnapshot(accountRef: accountID)
        }.value
    }

    /// Reads the active account's locally cached kind-3 follow list without
    /// blocking SwiftUI on the generated synchronous FFI call.
    func accountFollows(accountRef: String) async throws -> Set<String> {
        try await Task.detached(priority: .utility) { [marmot, accountRef] in
            Set(try marmot.accountFollows(accountRef: accountRef).map { $0.lowercased() })
        }.value
    }

    /// Resolves one follow relationship from Marmot's local kind-3 cache.
    func isFollowing(accountRef: String, userRef: String) async throws -> Bool {
        try await Task.detached(priority: .utility) { [marmot, accountRef, userRef] in
            try marmot.isFollowing(accountRef: accountRef, userRef: userRef)
        }.value
    }

    /// Publishes a follow-list replacement through Marmot and reports the
    /// resulting relationship rather than assuming the requested mutation.
    func setFollowing(
        accountRef: String,
        accountIdHex: String,
        isFollowing: Bool
    ) async throws -> Bool {
        let normalizedAccountId = accountIdHex.lowercased()
        let updated = if isFollowing {
            try await marmot.followUser(
                accountRef: accountRef,
                userRef: normalizedAccountId
            )
        } else {
            try await marmot.unfollowUser(
                accountRef: accountRef,
                userRef: normalizedAccountId
            )
        }
        return updated.contains { $0.caseInsensitiveCompare(normalizedAccountId) == .orderedSame }
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

    /// Reads one known chat-list row without transferring the complete list.
    func chatListRow(accountRef: String, groupIdHex: String) async throws -> ChatListRowFfi? {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex] in
            try marmot.chatListRow(accountRef: accountRef, groupIdHex: groupIdHex)
        }.value
    }

    /// Reads metadata-only composer drafts off the main actor. Attachment
    /// plaintext is deliberately omitted by the binding until one conversation
    /// is opened.
    func messageDrafts(accountRef: String) async throws -> [MessageDraftSummaryFfi] {
        try await Task.detached(priority: .utility) { [marmot, accountRef] in
            try marmot.messageDrafts(accountRef: accountRef)
        }.value
    }

    /// Hydrates one composer draft, including attachment plaintext, off the main
    /// actor so opening a media-heavy draft cannot block SwiftUI.
    func messageDraft(accountRef: String, groupIdHex: String) async throws -> MessageDraftFfi? {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex] in
            try marmot.messageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
        }.value
    }

    /// Persists one complete composer draft in the account's encrypted
    /// SQLCipher store without performing synchronous FFI work on MainActor.
    func saveMessageDraft(
        accountRef: String,
        groupIdHex: String,
        content: String,
        replyToMessageIdHex: String?,
        mediaAttachments: [MessageDraftAttachmentFfi]
    ) async throws -> MessageDraftFfi {
        try await Task.detached(priority: .utility) {
            [marmot, accountRef, groupIdHex, content, replyToMessageIdHex, mediaAttachments] in
            try marmot.saveMessageDraft(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                content: content,
                replyToMessageIdHex: replyToMessageIdHex,
                mediaAttachments: mediaAttachments
            )
        }.value
    }

    /// Deletes one composer draft from the encrypted account store.
    func deleteMessageDraft(accountRef: String, groupIdHex: String) async throws {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex] in
            try marmot.deleteMessageDraft(accountRef: accountRef, groupIdHex: groupIdHex)
        }.value
    }

    /// Reads everything required for all account and application badges in one
    /// local aggregate call, including manual-only and invitation attention.
    func accountUnreadSummaries() async throws -> [AccountUnreadFfi] {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.accountUnreadSummary()
        }.value
    }

    /// Reads the telemetry install id off the main actor before runtime startup
    /// config is applied.
    func telemetryInstallId() async throws -> String {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.telemetryInstallId()
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

    /// Applies the relay plane's exact dial-boundary policy off the main actor.
    /// Results preserve input order and cardinality, including rejected URLs.
    func classifyRelayEndpoints(_ endpoints: [String]) async -> [RelayEndpointClassificationFfi] {
        await Task.detached(priority: .utility) { [marmot, endpoints] in
            marmot.classifyRelayEndpoints(endpoints: endpoints)
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

    /// Writes the local-notification preference off the main actor. The
    /// generated Marmot binding is synchronous storage FFI.
    func setLocalNotificationsEnabled(
        accountRef: String,
        enabled: Bool
    ) async throws -> NotificationSettingsFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef, enabled] in
            try marmot.setLocalNotificationsEnabled(accountRef: accountRef, enabled: enabled)
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

    /// Non-destructive sign-out: deactivate the account while preserving its
    /// local store, keys, media, and drafts for a later sign-in.
    func signOut(accountRef: String, deleteKeyPackages: Bool = true) async throws -> SignOutOutcomeFfi {
        try await marmot.signOut(accountRef: accountRef, deleteKeyPackages: deleteKeyPackages)
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
                telemetrySettings: PrivacyTelemetrySettingsProjection(settings: marmot.usageDiagnosticsSettings()),
                auditSettings: PrivacyAuditSettingsProjection(settings: marmot.auditLogSettings()),
                auditFileRows: AuditFileRowProjection.rows(from: marmot.auditLogFiles())
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

    /// Sets or clears a manual unread reminder without blocking MainActor on
    /// the synchronous storage-backed FFI command.
    func setChatManuallyUnread(
        accountRef: String,
        groupIdHex: String,
        manuallyUnread: Bool
    ) async throws -> ChatListRowFfi? {
        try await Task.detached(priority: .utility) {
            [marmot, accountRef, groupIdHex, manuallyUnread] in
            try marmot.setChatManuallyUnread(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                manuallyUnread: manuallyUnread
            )
        }.value
    }

    /// Updates the device-local pinned section off MainActor. Marmot returns
    /// the complete authoritative order and publishes a full chat-list
    /// subscription snapshot for row projection updates.
    func setChatPinned(
        accountRef: String,
        groupIdHex: String,
        pinned: Bool
    ) async throws -> ChatPinStateFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef, groupIdHex, pinned] in
            try marmot.setChatPinned(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                pinned: pinned
            )
        }.value
    }

    /// Reorders the complete device-local pinned section off MainActor.
    func setPinnedChatOrder(
        accountRef: String,
        orderedGroupIds: [String]
    ) async throws -> ChatPinStateFfi {
        try await Task.detached(priority: .utility) { [marmot, accountRef, orderedGroupIds] in
            try marmot.setPinnedChatOrder(
                accountRef: accountRef,
                orderedGroupIds: orderedGroupIds
            )
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
        limit: UInt32? = nil
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

    /// Throwing read for callers that must distinguish "no kind:0 exists"
    /// from a failed read — the projection batch above erases errors with
    /// `try?`, so its output can't gate a destructive publish.
    func userProfileForEditing(accountIdHex: String) async throws -> UserProfileMetadataFfi? {
        let marmot = self.marmot
        return try await Task.detached(priority: .utility) {
            try marmot.userProfile(accountIdHex: accountIdHex)
        }.value
    }

    static func profileProjections(
        for requests: [ProfileProjectionRequest],
        marmot: Marmot
    ) async -> [String: ProfileDisplayProjection] {
        await Task.detached(priority: .utility) {
            var projections: [String: ProfileDisplayProjection] = [:]
            for start in stride(from: 0, to: requests.count, by: 100) {
                let page = Array(requests[start..<min(start + 100, requests.count)])
                let rows = try? marmot.cachedIdentityProjections(
                    accountIdHexes: page.map(\.accountIdHex)
                )
                for (index, request) in page.enumerated() {
                    let row = rows.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    let profile = row?.profile
                    projections[request.accountIdHex] = ProfileDisplayProjection(
                        profile: profile,
                        projectedName: profile?.displayName ?? profile?.name,
                        localAccountLabel: request.localAccountLabel ?? row?.localLabel
                    )
                }
            }
            return projections
        }.value
    }

    func existingDirectConversation(
        accountRef: String,
        peerAccountId: String
    ) async throws -> ExistingDirectConversationFfi? {
        try await marmot.existingDirectConversation(
            accountRef: accountRef,
            peerAccountId: peerAccountId
        )
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

    func createGroupWithInitialImage(
        accountRef: String,
        name: String,
        memberRefs: [String],
        description: String?,
        initialImage: InitialGroupImageFfi?
    ) async throws -> String {
        try await marmot.createGroupWithInitialImage(
            accountRef: accountRef,
            name: name,
            memberRefs: memberRefs,
            description: description,
            initialImage: initialImage
        )
    }

    func createGroupWithOptionsDetailed(
        accountRef: String,
        name: String,
        memberRefs: [String],
        options: CreateGroupOptionsFfi
    ) async throws -> CreatedGroupFfi {
        try await marmot.createGroupWithOptionsDetailed(
            accountRef: accountRef,
            name: name,
            memberRefs: memberRefs,
            options: options
        )
    }

    func prewarmGroupMemberKeyPackages(
        accountRef: String,
        memberRefs: [String]
    ) async throws -> MemberKeyPackagePrewarmSummaryFfi {
        try await marmot.prewarmGroupMemberKeyPackages(
            accountRef: accountRef,
            memberRefs: memberRefs
        )
    }

    func setGroupArchived(accountRef: String, groupIdHex: String, archived: Bool) async throws -> AppGroupRecordFfi {
        try await marmot.setGroupArchived(accountRef: accountRef, groupIdHex: groupIdHex, archived: archived)
    }

    func sendText(accountRef: String, groupIdHex: String, text: String) async throws -> SendSummaryFfi {
        try await marmot.sendText(accountRef: accountRef, groupIdHex: groupIdHex, text: text)
    }

    /// Re-drives a group's committed-but-undelivered messages to the relays
    /// without minting new events.
    func retryGroupConvergence(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.retryGroupConvergence(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    /// Pumps every account worker's relay catch-up — the same recovery the
    /// app runs on foreground activation.
    func catchUpAccounts() async throws {
        try await marmot.catchUpAccounts()
    }

    /// Wakes MDK's exact durable outbound retries after the host observes that
    /// connectivity is usable again. This does not create a new app event.
    func notifyConnectivityRestored() async throws {
        try await marmot.notifyConnectivityRestored()
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

    func acceptGroupInvite(accountRef: String, groupIdHex: String) async throws -> AppGroupRecordFfi {
        try await marmot.acceptGroupInvite(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func declineGroupInvite(accountRef: String, groupIdHex: String) async throws -> GroupInviteDeclineResultFfi {
        try await marmot.declineGroupInvite(accountRef: accountRef, groupIdHex: groupIdHex)
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

    func enableGroupDisbanding(accountRef: String, groupIdHex: String) async throws -> GroupMutationResultFfi {
        try await marmot.enableGroupDisbanding(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func disbandGroup(accountRef: String, groupIdHex: String) async throws -> DisbandRequestFfi {
        try await marmot.disbandGroup(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func acknowledgeDisbandFailure(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.acknowledgeDisbandFailure(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func updateGroupProfile(accountRef: String, groupIdHex: String, name: String?, description: String?) async throws -> SendSummaryFfi {
        try await marmot.updateGroupProfile(accountRef: accountRef, groupIdHex: groupIdHex, name: name, description: description)
    }

    func updateGroupAvatarUrl(accountRef: String, groupIdHex: String, url: String?, dim: String?, thumbhash: String?) async throws -> SendSummaryFfi {
        try await marmot.updateGroupAvatarUrl(accountRef: accountRef, groupIdHex: groupIdHex, url: url, dim: dim, thumbhash: thumbhash)
    }

    func updateGroupImage(
        accountRef: String,
        groupIdHex: String,
        plaintext: Data,
        mediaType: String
    ) async throws -> SendSummaryFfi {
        try await marmot.updateGroupImage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            plaintext: plaintext,
            mediaType: mediaType
        )
    }

    func clearGroupImage(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.clearGroupImage(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func downloadGroupBlossomImage(accountRef: String, groupIdHex: String) async throws -> Data {
        try await marmot.downloadGroupBlossomImage(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func downloadProfileImage(url: String, maxBytes: UInt64) async throws -> Data {
        try await marmot.downloadProfileImage(url: url, maxBytes: maxBytes)
    }

    func updateMessageRetention(accountRef: String, groupIdHex: String, disappearingMessageSecs: UInt64) async throws -> SendSummaryFfi {
        try await marmot.updateMessageRetention(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            disappearingMessageSecs: disappearingMessageSecs
        )
    }

    func sweepExpiredRetention(
        accountRef: String,
        nowMs: UInt64
    ) async throws -> RetentionSweepReportFfi {
        try await marmot.sweepExpiredRetention(accountRef: accountRef, nowMs: nowMs)
    }

    func leaveGroup(accountRef: String, groupIdHex: String) async throws -> SendSummaryFfi {
        try await marmot.leaveGroup(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func deleteGroupLocal(accountRef: String, groupIdHex: String) async throws -> Bool {
        try await marmot.deleteGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupMembers(accountRef: String, groupIdHex: String) async throws -> [AppGroupMemberRecordFfi] {
        try await marmot.groupMembers(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupMemberIdsPage(
        accountRef: String,
        groupIdsHex: [String]
    ) async throws -> [AppGroupMemberIdsFfi] {
        try await marmot.groupMemberIdsPage(
            accountRef: accountRef,
            groupIdsHex: groupIdsHex
        )
    }

    func groupDetails(accountRef: String, groupIdHex: String) async throws -> GroupDetailsFfi {
        try await marmot.groupDetails(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupRoster(accountRef: String, groupIdHex: String) async throws -> GroupRosterFfi {
        try await marmot.groupRoster(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupManagementState(accountRef: String, groupIdHex: String) async throws -> GroupManagementStateFfi {
        try await marmot.groupManagementState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupConversationSnapshot(
        accountRef: String,
        groupIdHex: String
    ) async throws -> GroupConversationSnapshotFfi {
        try await marmot.groupConversationSnapshot(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    func groupMlsState(accountRef: String, groupIdHex: String) async throws -> AppGroupMlsStateFfi {
        try await marmot.groupMlsState(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupPushDebugInfo(accountRef: String, groupIdHex: String) async throws -> GroupPushDebugInfoFfi {
        try await marmot.groupPushDebugInfo(accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func groupMaintenanceStatus(
        accountRef: String,
        groupIdHex: String
    ) async throws -> GroupMaintenanceStatusFfi {
        try await marmot.groupMaintenanceStatus(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    func quarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi] {
        try await marmot.quarantinedGroups(accountRef: accountRef)
    }

    func retryHydrateQuarantinedGroup(
        accountRef: String,
        groupIdHex: String
    ) async throws -> Bool {
        try await marmot.retryHydrateQuarantinedGroup(
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    func deleteMessage(accountRef: String, groupIdHex: String, targetMessageId: String) async throws -> SendSummaryFfi {
        try await marmot.deleteMessage(accountRef: accountRef, groupIdHex: groupIdHex, targetMessageId: targetMessageId)
    }

    func editMessage(accountRef: String, groupIdHex: String, targetMessageId: String, content: String) async throws -> SendSummaryFfi {
        try await marmot.editMessage(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            targetMessageId: targetMessageId,
            content: content
        )
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

    func publishUserProfileUsingAccountRelays(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws -> UserProfileMetadataFfi {
        try await marmot.publishUserProfileUsingAccountRelays(
            accountRef: accountRef,
            profile: profile
        )
    }

    func uploadProfileImage(
        accountRef: String,
        data: Data,
        mediaType: String,
        blossomServer: String?
    ) async throws -> String {
        try await marmot.uploadProfileImage(
            accountRef: accountRef,
            data: data,
            mediaType: mediaType,
            blossomServer: blossomServer
        )
    }

    func refreshProfile(accountIdHex: String, relays: [String]) async throws {
        try await marmot.refreshProfile(accountIdHex: accountIdHex, relays: relays)
    }

    func userRelayLists(accountIdHex: String) async throws -> AccountRelayListsFfi {
        try await Task.detached(priority: .utility) { [marmot, accountIdHex] in
            try marmot.userRelayLists(accountIdHex: accountIdHex)
        }.value
    }

    func refreshUserRelayLists(
        accountIdHex: String,
        relays: [String]
    ) async throws -> AccountRelayListsFfi {
        try await marmot.refreshUserRelayLists(
            accountIdHex: accountIdHex,
            relays: relays
        )
    }

    func userProfileWebsite(accountIdHex: String) async throws -> String? {
        try await Task.detached(priority: .utility) { [marmot, accountIdHex] in
            try marmot.userProfileWebsite(accountIdHex: accountIdHex)
        }.value
    }

    func accountKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws -> [AccountKeyPackageFfi] {
        try await marmot.accountKeyPackages(accountRef: accountRef, bootstrapRelays: bootstrapRelays)
    }

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        try await marmot.publishNewKeyPackage(accountRef: accountRef)
    }

    func republishKeyPackage(accountRef: String) async throws -> UInt64 {
        try await marmot.republishKeyPackage(accountRef: accountRef)
    }

    func keyPackageMaintenanceStatus(
        accountRef: String
    ) async throws -> KeyPackageMaintenanceStatusFfi? {
        try await marmot.keyPackageMaintenanceStatus(accountRef: accountRef)
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

    func subscribeChats(accountRef: String, includeArchived: Bool) async throws -> ChatsSubscription {
        try await marmot.subscribeChats(accountRef: accountRef, includeArchived: includeArchived)
    }

    /// Materializes a chats subscription snapshot off the main actor.
    /// `ChatsSubscription.snapshot()` is a synchronous UniFFI call backed by
    /// local Marmot storage.
    func chatsSubscriptionSnapshot(
        _ subscription: ChatsSubscription
    ) async -> [AppGroupRecordFfi] {
        await Task.detached(priority: .utility) { [subscription] in
            subscription.snapshot()
        }.value
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
        // Optional exporters cannot turn missing consent/configuration into a startup failure.
        try? await configureTelemetryRuntime()
        try? await configureProductAnalytics()
        try await marmot.start()
    }

    func recordHostPerformance(
        operation: HostPerformanceOperationFfi,
        durationMs: UInt64,
        outcome: HostPerformanceOutcomeFfi
    ) {
        marmot.recordHostPerformance(
            operation: operation,
            durationMs: durationMs,
            outcome: outcome
        )
    }

    func appPerformanceSnapshot() -> AppPerformanceSnapshotFfi {
        marmot.appPerformanceSnapshot()
    }

    func relayHealth() async -> RelayHealthFfi {
        await marmot.relayHealth()
    }

    func configureTelemetryRuntime() async throws {
        try await marmot.setRelayTelemetryRuntimeConfig(
            config: telemetryConfig.runtimeConfig(installId: "")
        )
    }

    func configureProductAnalytics() async throws {
        try await Task.detached(priority: .utility) { [marmot, productConfig] in
            try marmot.setProductAnalyticsRuntimeConfig(config: productConfig.runtimeConfig)
        }.value
    }

    func deviceDiagnosticsSnapshot() async throws -> DeviceDiagnosticsSnapshot {
        try await Task.detached(priority: .utility) { [marmot] in
            try DeviceDiagnosticsSnapshot(
                settings: marmot.usageDiagnosticsSettings(),
                status: marmot.usageDiagnosticsStatus(),
                auditEnabled: marmot.auditLogSettings().enabled
            )
        }.value
    }

    func setUsageDiagnosticsConsent(_ enabled: Bool) async throws -> UsageDiagnosticsSettingsFfi {
        try await Task.detached(priority: .utility) { [marmot] in
            try marmot.setUsageDiagnosticsConsent(enabled: enabled)
        }.value
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
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

    /// Shown in place of an editable relay whose display sanitized entirely
    /// away, so a control/bidi-only entry stays visible and individually
    /// deletable rather than collapsing into a blank row.
    static let invalidRelayMessage = L10n.string("Invalid relay")

    static func editableRelays(from lists: AccountRelayListsFfi) -> [String] {
        normalizedRelayURLs(lists.defaultRelays.isEmpty ? lists.nip65.relays : lists.defaultRelays)
    }

    /// Display string for one editable account-relay row. Same sanitizer as
    /// `publishedRelayRows` (#298 / #306 / #467), but strictly 1:1 with the
    /// input — never drops or collapses entries — so `RelaysView`'s
    /// delete-by-index stays aligned with `currentRelays`. Falls back to
    /// `invalidRelayMessage` when nothing renderable remains.
    static func editableRelayDisplay(_ raw: String) -> String {
        ContentSanitizer.relayDisplayLine(raw, maxLength: 120) ?? invalidRelayMessage
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
        let sanitized = relays.compactMap { ContentSanitizer.relayDisplayLine($0, maxLength: 120) }
        return sanitized.isEmpty ? [notPublishedMessage] : sanitized
    }

    /// Stable display labels for relay-list kinds not yet published.
    static func missingRelayLabels(_ missing: [MissingRelayListKindFfi]) -> [String] {
        missing.map {
            switch $0 {
            case .nip65:
                L10n.string("NIP-65")
            case .inbox:
                L10n.string("Inbox")
            }
        }
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

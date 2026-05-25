import Foundation
import Observation
import MarmotKit

/// Root observable state for the app.
///
/// Holds the `Marmot` handle, the current set of `AccountSummaryFfi`, and
/// which account is active. View models observe this through
/// `@Environment(AppState.self)`. Subscriptions and sends are always
/// performed against `activeAccountRef`.
@Observable
final class AppState {

    enum Phase: Equatable {
        case bootstrapping
        case onboarding
        case ready
        case failed(String)
    }

    /// Where the user is in the global flow. Drives the root router.
    private(set) var phase: Phase = .bootstrapping

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    private(set) var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion.
    var activeAccountRef: String? {
        didSet {
            if let ref = activeAccountRef {
                UserDefaults.standard.set(ref, forKey: Self.activeAccountKey)
            }
        }
    }

    /// Developer mode: surfaces extra debugging UI (e.g. MLS group internals
    /// on the chat-details screen). Off by default; toggled in Settings.
    var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey)
        }
    }

    /// Recently-used reaction emojis, most-recent first. Drives the quick row
    /// in the message actions overlay.
    private(set) var recentReactions: [String]

    static let defaultReactions = ["👍", "❤️", "😂", "🎉", "😮"]

    /// The five emojis to show in the quick-reaction row: recents first,
    /// topped up with defaults.
    var quickReactions: [String] {
        var result = recentReactions
        for emoji in Self.defaultReactions where result.count < 5 {
            if !result.contains(emoji) { result.append(emoji) }
        }
        return Array(result.prefix(5))
    }

    func addRecentReaction(_ emoji: String) {
        var list = recentReactions.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentReactions = Array(list.prefix(12))
        UserDefaults.standard.set(recentReactions, forKey: Self.recentReactionsKey)
    }

    let client: MarmotClient

    /// Cache of best-known display names keyed by account id hex. Derived
    /// from `profiles` when available. Read-only from view code.
    private(set) var displayNames: [String: String] = [:]

    /// Cache of full Nostr kind:0 profiles keyed by account id hex. Populated
    /// on demand via `profile(forAccountIdHex:)`. Read-only from view code.
    private(set) var profiles: [String: UserProfileMetadataFfi] = [:]

    /// Cache of npub (bech32) forms keyed by account id hex. Conversion is
    /// deterministic and offline, so these never go stale.
    private(set) var npubs: [String: String] = [:]

    /// Most recent transient banner. View code reads this via the
    /// `.toastHost()` modifier on the root view.
    private(set) var activeToast: Toast?
    private var toastDismissTask: Task<Void, Never>?

    /// A profile to present (set by a scanned QR or an opened deep link).
    /// MainView binds a sheet to this.
    private(set) var pendingProfile: ProfileLink?

    struct ProfileLink: Identifiable, Equatable {
        let npub: String
        var id: String { npub }
    }

    /// A chat (group id hex) to navigate to once any presenting sheets close —
    /// set right after creating a chat from the composer or a scanned profile.
    /// ChatsListView observes this to push the conversation.
    private(set) var pendingChatId: String?

    /// Tracks in-flight directory fetches so we don't pile up duplicate work.
    private var directoryFetchesInFlight: Set<String> = []

    private static let activeAccountKey = "marmot.activeAccountRef"
    private static let developerModeKey = "marmot.developerMode"
    private static let recentReactionsKey = "marmot.recentReactions"
    static let agentTextStreamQuicBrokerCandidate = "quic://quic-broker.ipf.dev:4450"
    static let agentTextStreamQuicCandidates = [agentTextStreamQuicBrokerCandidate]

    init(client: MarmotClient) {
        self.client = client
        self.activeAccountRef = UserDefaults.standard.string(forKey: Self.activeAccountKey)
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
    }

    /// Production entry point. Builds a keychain-backed client; if secure
    /// storage can't be initialized the app can't run safely, so we trap
    /// with a clear message rather than fall back to insecure on-disk keys.
    convenience init() {
        do {
            self.init(client: try MarmotClient())
        } catch {
            fatalError("Failed to initialize Keychain-backed secret storage: \(error)")
        }
    }

    /// Convenience accessor for the underlying FFI handle.
    var marmot: Marmot { client.marmot }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch.
    func bootstrap() async {
        do {
            try await marmot.start()
            try await refreshAccounts()
            if accounts.isEmpty {
                phase = .onboarding
            } else {
                if activeAccountRef == nil
                    || !accounts.contains(where: { $0.label == activeAccountRef }) {
                    activeAccountRef = accounts.first?.label
                }
                phase = .ready
                // Warm the active account's profile (name + avatar) right away
                // so it's visible without waiting for a screen to request it.
                if let activeId = activeAccount?.accountIdHex {
                    _ = await profile(forAccountIdHex: activeId)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshAccounts() async throws {
        let listed = try await Task.detached { [marmot] in
            try marmot.listAccounts()
        }.value
        accounts = listed
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.createIdentity(
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        if phase == .onboarding { phase = .ready }
        return summary
    }

    /// Import an existing local-signing identity (nsec).
    @discardableResult
    func importIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.login(
            identity: identity,
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        if phase == .onboarding { phase = .ready }
        return summary
    }

    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }

    func relayLists(for accountRef: String) -> AccountRelayListsFfi? {
        try? marmot.accountRelayLists(accountRef: accountRef)
    }

    func relayPublishRelays(for accountRef: String) -> [String] {
        guard let lists = relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        let relays = RelaySettings.editableRelays(from: lists)
        return relays.isEmpty ? MarmotClient.seedRelays : relays
    }

    func relayBootstrapRelays(for accountRef: String) -> [String] {
        guard let lists = relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        return RelaySettings.bootstrapRelays(from: lists)
    }

    @discardableResult
    func startAgentTextStream(
        accountRef: String,
        groupIdHex: String,
        streamIdHex: String? = nil
    ) async throws -> AgentStreamStartFfi {
        try await marmot.startAgentTextStream(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            streamIdHex: streamIdHex,
            quicCandidates: Self.agentTextStreamQuicCandidates
        )
    }

    // MARK: - Profiles & display names

    /// Full Nostr profile for an account id. Returns the cached value
    /// immediately if known; otherwise does a fast synchronous read from the
    /// runtime's directory cache, and on a miss schedules a background relay
    /// fetch so a later call hydrates. `nil` until something is known.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        if let cached = profiles[id] { return cached }
        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return local
        }
        Task { await refreshProfile(forAccountIdHex: id) }
        return nil
    }

    /// A display name we actually *know* for an account: projected kind:0
    /// display_name/name, then a cached name, then a local account's label.
    /// `nil` when nothing better than the raw id is available, so callers can
    /// choose their own fallback (e.g. an npub for a DM peer).
    @MainActor
    func knownDisplayName(forAccountIdHex id: String) -> String? {
        if let p = profile(forAccountIdHex: id), let name = Self.name(from: p) {
            return name
        }
        if let cached = displayNames[id] { return cached }
        if let owned = accounts.first(where: { $0.accountIdHex == id }), !owned.label.isEmpty {
            return owned.label
        }
        return nil
    }

    /// Best-effort display name. Prefers the projected kind:0 display_name /
    /// name, then a local account's label, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        knownDisplayName(forAccountIdHex: id) ?? IdentityFormatter.short(id)
    }

    /// Picture URL for an account id, if its profile has a *safe* one.
    /// Untrusted: only http(s) URLs with a host pass the sanitizer.
    @MainActor
    func avatarURL(forAccountIdHex id: String) -> URL? {
        ProfileSanitizer.imageURL(profile(forAccountIdHex: id)?.picture)
    }

    /// Store a profile in the cache and derive its display name. Called after
    /// a successful publish so the editor and chrome update immediately.
    @MainActor
    func cacheProfile(_ profile: UserProfileMetadataFfi, for id: String) {
        profiles[id] = profile
        if let name = Self.name(from: profile) {
            displayNames[id] = name
        }
    }

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard !directoryFetchesInFlight.contains(id) else { return }
        directoryFetchesInFlight.insert(id)
        defer { directoryFetchesInFlight.remove(id) }

        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return
        }

        // Fetch this account's OWN kind:0 through the active account's relay
        // lists. Marmot owns those lists; iOS only asks for the current view.
        let relays = activeAccountRef.map(relayBootstrapRelays(for:)) ?? MarmotClient.seedRelays
        try? await marmot.refreshProfile(accountIdHex: id, relays: relays)

        if let fetched = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(fetched, for: id)
        } else if let name = marmot.displayName(accountIdHex: id), !name.isEmpty {
            displayNames[id] = name
        }
    }

    private static func name(from profile: UserProfileMetadataFfi) -> String? {
        // Untrusted kind:0 content — sanitize before it's used as a name.
        ProfileSanitizer.displayName(profile.displayName ?? profile.name)
    }

    // MARK: - npub

    /// The `npub…` bech32 form of an account id hex. Falls back to the hex
    /// if conversion fails (shouldn't, for a valid pubkey).
    @MainActor
    func npub(forAccountIdHex id: String) -> String {
        if let cached = npubs[id] { return cached }
        let value = marmot.npub(accountIdHex: id) ?? id
        npubs[id] = value
        return value
    }

    /// Truncated npub for compact UI (e.g. `npub1abc…wxyz`).
    @MainActor
    func shortNpub(forAccountIdHex id: String) -> String {
        IdentityFormatter.short(npub(forAccountIdHex: id))
    }

    // MARK: - Toasts

    @MainActor
    func present(_ toast: Toast) {
        toastDismissTask?.cancel()
        activeToast = toast
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.activeToast?.id == id else { return }
            self.activeToast = nil
        }
    }

    @MainActor
    func dismissToast() {
        toastDismissTask?.cancel()
        activeToast = nil
    }

    // MARK: - Profile routing (QR scan / deep link)

    @MainActor
    func presentProfile(npub: String) {
        pendingProfile = ProfileLink(npub: npub)
    }

    @MainActor
    func clearPendingProfile() {
        pendingProfile = nil
    }

    /// Request navigation into a chat (e.g. just after creating one).
    @MainActor
    func presentChat(groupIdHex: String) {
        pendingChatId = groupIdHex
    }

    @MainActor
    func clearPendingChat() {
        pendingChatId = nil
    }

    /// Route an inbound deep link (from `.onOpenURL`).
    @MainActor
    func handle(url: URL) {
        switch DeepLink.parse(url) {
        case .profile(let npub):
            presentProfile(npub: npub)
        case .chat(let groupIdHex):
            presentChat(groupIdHex: groupIdHex)
        case nil:
            break
        }
    }
}

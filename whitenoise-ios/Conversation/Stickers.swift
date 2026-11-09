import Observation
import UIKit
import MarmotKit

// Sonar sticker packs (kind 30031) are public Nostr events. A sticker message
// is a kind-9 with empty content and a `sticker` tag naming the pack, the
// shortcode and the image's SHA-256. MDK authorizes and validates every
// image; its bytes come from a public URL the pack's author chose, so loading
// one discloses this device's IP address to that server.

/// The account and runtime sticker state is read under.
nonisolated struct StickerScope: Hashable, Sendable {
    let accountRef: String
    let runtimeGeneration: Int
}

/// One sticker's immutable identity: pack, shortcode and image hash.
nonisolated struct StickerKey: Hashable, Sendable {
    let packCoordinate: String
    let shortcode: String
    let plaintextSha256: String

    init(_ ref: StickerRefFfi) {
        packCoordinate = ref.packCoordinate
        shortcode = ref.shortcode
        plaintextSha256 = ref.plaintextSha256
    }

    init(_ sticker: StickerFfi) {
        packCoordinate = sticker.packCoordinate
        shortcode = sticker.shortcode
        plaintextSha256 = sticker.plaintextSha256
    }

    var ref: StickerRefFfi {
        StickerRefFfi(packCoordinate: packCoordinate, shortcode: shortcode, plaintextSha256: plaintextSha256)
    }
}

nonisolated enum StickerBubbleLayout {
    /// A sticker replaces the bubble only when its kind-9 carries nothing
    /// else. MDK reads the sticker tag independently of the content, so a
    /// caption, reply quote or attachment beside it must still show.
    static func standsAlone(plaintext: String, hasReply: Bool, hasMedia: Bool) -> Bool {
        !hasReply && !hasMedia && plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

nonisolated enum StickerLoadPolicy {
    /// Whether a sticker in the timeline loads without a tap. Loading contacts
    /// the pack author's server, so a received sticker loads by itself only
    /// from a pack the person installed, and only while Photos auto-download
    /// allows it. Their own stickers were already loaded to send them.
    static func loadsAutomatically(isFromMe: Bool, packInstalled: Bool, autoDownloadImages: Bool) -> Bool {
        isFromMe || (packInstalled && autoDownloadImages)
    }

    /// The text that stands in for a sticker: its emoji when the pack names
    /// one, otherwise the generic label. Peer-controlled, so sanitized and
    /// bounded to one grapheme-sized run.
    static func label(emoji: String?) -> String {
        let trimmed = ContentSanitizer.messageBody(emoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4, trimmed.unicodeScalars.contains(where: \.properties.isEmojiPresentation)
        else { return L10n.string("Sticker") }
        return L10n.formatted("%@ Sticker", trimmed)
    }

    /// The spoken description of a sticker.
    static func accessibilityLabel(alt: String?, emoji: String?) -> String {
        let alt = ContentSanitizer.messageBody(alt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alt.isEmpty else { return label(emoji: emoji) }
        return L10n.formatted("Sticker: %@", String(alt.prefix(120)))
    }
}

nonisolated enum StickerPackPresentation {
    /// Packs to offer for discovery: those not installed, in MDK's order.
    static func discoverable(_ packs: [StickerPackFfi], installed: Set<String>) -> [StickerPackFfi] {
        packs.filter { !$0.installed && !installed.contains($0.coordinate) && !$0.stickers.isEmpty }
    }

    /// A pasted link, coordinate or `naddr`, or nil when there is nothing to
    /// look up. MDK parses and validates it; this only trims and bounds it.
    static func lookupInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else { return nil }
        return trimmed
    }

    static func title(_ pack: StickerPackFfi) -> String {
        let title = ContentSanitizer.messageBody(pack.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.string("Sticker Pack") : String(title.prefix(80))
    }

    static func description(_ pack: StickerPackFfi) -> String? {
        let text = ContentSanitizer.messageBody(pack.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }

    enum DiscoveryState: Equatable {
        case loading
        case packs
        /// The relays answered and hold no packs.
        case noneOnRelays
        case noMatches
        /// Relays couldn't be reached and nothing is cached to show.
        case unreachable(message: String)
    }

    /// What the Discover section shows. Cached packs stay listed when a
    /// refresh fails; a failed refresh never reads as "there are none".
    static func discoveryState(isLoading: Bool, packCount: Int, search: String,
                               syncError: String?) -> DiscoveryState {
        if packCount > 0 { return .packs }
        if isLoading { return .loading }
        if let syncError { return .unreachable(message: syncError) }
        let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return searching ? .noMatches : .noneOnRelays
    }

    static func summary(_ pack: StickerPackFfi) -> String {
        L10n.plural("%lld stickers", Int64(pack.stickers.count))
    }
}

/// Loads and caches decoded sticker images for one account and runtime.
///
/// MDK keeps no copy of a sticker image, so this keeps a bounded in-memory
/// cache. Concurrent requests for one sticker share one download. A failed
/// load stays failed until an explicit retry, so a broken sticker never
/// re-dials its server from scrolling.
@MainActor
final class StickerAssetStore {
    typealias Fetch = @MainActor (_ accountRef: String, _ ref: StickerRefFfi) async throws -> StickerAssetFfi
    typealias Decode = @MainActor (Data, Int) async -> UIImage?

    struct Loaded {
        let image: UIImage
        let sticker: StickerFfi
    }

    static let imageLimit = 96
    /// Large enough for a timeline sticker at 3x.
    static let pixelSize = 480

    private struct Key: Hashable {
        let scope: StickerScope
        let sticker: StickerKey
    }

    private let scopeProvider: @MainActor () -> StickerScope?
    private let fetch: Fetch
    private let decode: Decode
    private var scope: StickerScope?
    private var images: [Key: Loaded] = [:]
    private var order: [Key] = []
    private var failures: Set<Key> = []
    private var inFlight: [Key: Task<Loaded?, Never>] = [:]

    init(
        scopeProvider: @escaping @MainActor () -> StickerScope?,
        fetch: @escaping Fetch,
        decode: @escaping Decode = { data, pixelSize in
            await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: pixelSize, scale: 3)
        }
    ) {
        self.scopeProvider = scopeProvider
        self.fetch = fetch
        self.decode = decode
    }

    func cached(_ sticker: StickerKey) -> Loaded? {
        guard let scope = syncedScope() else { return nil }
        return images[Key(scope: scope, sticker: sticker)]
    }

    func hasFailed(_ sticker: StickerKey) -> Bool {
        guard let scope = syncedScope() else { return false }
        return failures.contains(Key(scope: scope, sticker: sticker))
    }

    /// The sticker's image, downloading it unless it already failed.
    func image(for sticker: StickerKey) async -> Loaded? {
        guard let scope = syncedScope() else { return nil }
        let key = Key(scope: scope, sticker: sticker)
        if let cached = images[key] { return cached }
        guard !failures.contains(key) else { return nil }
        return await load(key)
    }

    /// Clears an earlier failure and downloads again, for an explicit tap.
    func retry(_ sticker: StickerKey) async -> Loaded? {
        guard let scope = syncedScope() else { return nil }
        let key = Key(scope: scope, sticker: sticker)
        failures.remove(key)
        return await image(for: sticker)
    }

    private func load(_ key: Key) async -> Loaded? {
        let task = inFlight[key] ?? Task { [fetch, decode] in
            do {
                let asset = try await fetch(key.scope.accountRef, key.sticker.ref)
                guard let image = await decode(asset.bytes, Self.pixelSize) else { return nil }
                return Loaded(image: image, sticker: asset.sticker)
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let loaded = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        guard scopeProvider() == key.scope else { return nil }
        if let loaded {
            store(loaded, for: key)
        } else {
            failures.insert(key)
        }
        return loaded
    }

    private func store(_ loaded: Loaded, for key: Key) {
        if images.updateValue(loaded, forKey: key) == nil { order.append(key) }
        while order.count > Self.imageLimit {
            images[order.removeFirst()] = nil
        }
    }

    private func syncedScope() -> StickerScope? {
        let current = scopeProvider()
        if current != scope {
            images.removeAll()
            order.removeAll()
            failures.removeAll()
            inFlight.values.forEach { $0.cancel() }
            inFlight.removeAll()
            scope = current
        }
        return current
    }
}

/// The account's sticker packs as the picker and timeline need them.
@Observable
@MainActor
final class StickerLibrary {
    typealias Packs = @MainActor (_ accountRef: String, _ installedOnly: Bool, _ search: String?) async throws -> [StickerPackFfi]
    typealias Sync = @MainActor (_ accountRef: String) async throws -> Void
    typealias PackAction = @MainActor (_ accountRef: String, _ input: String) async throws -> StickerPackFfi
    typealias Uninstall = @MainActor (_ accountRef: String, _ input: String) async throws -> Void

    private(set) var installed: [StickerPackFfi] = []
    private(set) var installedCoordinates: Set<String> = []
    private(set) var hasLoadedInstalled = false
    private(set) var isSyncing = false

    @ObservationIgnored private let scopeProvider: @MainActor () -> StickerScope?
    @ObservationIgnored private let packs: Packs
    @ObservationIgnored private let syncPacks: Sync
    @ObservationIgnored private let fetchPack: PackAction
    @ObservationIgnored private let install: PackAction
    @ObservationIgnored private let uninstall: Uninstall
    @ObservationIgnored private var scope: StickerScope?
    @ObservationIgnored private var loadingInstalled: Task<Void, Never>?
    @ObservationIgnored private var syncedScope: StickerScope?
    @ObservationIgnored private var syncing: (scope: StickerScope, task: Task<Void, Error>)?

    init(scopeProvider: @escaping @MainActor () -> StickerScope?, packs: @escaping Packs, sync: @escaping Sync,
         fetchPack: @escaping PackAction, install: @escaping PackAction, uninstall: @escaping Uninstall) {
        self.scopeProvider = scopeProvider
        self.packs = packs
        self.syncPacks = sync
        self.fetchPack = fetchPack
        self.install = install
        self.uninstall = uninstall
    }

    /// Read-only, so a view body can ask without changing observed state.
    /// Reads the observed set first: `scope` is not observed, so a body that
    /// stopped at the scope check would miss the first load.
    func isInstalled(_ coordinate: String) -> Bool {
        let contains = installedCoordinates.contains(coordinate)
        return contains && scopeProvider() == scope
    }

    /// Reads the installed packs once per account and runtime.
    func loadInstalledIfNeeded() async {
        guard currentScope() != nil else { return }
        if hasLoadedInstalled { return }
        if let loadingInstalled { return await loadingInstalled.value }
        let task = Task { await reloadInstalled() }
        loadingInstalled = task
        await task.value
        loadingInstalled = nil
    }

    func reloadInstalled() async {
        guard let scope = currentScope() else { return }
        guard let packs = try? await packs(scope.accountRef, true, nil), currentScope() == scope else { return }
        installed = packs
        installedCoordinates = Set(packs.map(\.coordinate))
        hasLoadedInstalled = true
    }

    /// Refreshes discovery and the installed list from relays, once per
    /// account and runtime unless forced by pull to refresh. The installed
    /// packs on screen stay usable if it fails.
    /// A caller arriving while a sync runs waits for it and gets its outcome.
    func sync(force: Bool = false) async throws {
        guard let scope = currentScope() else { return }
        if let running = syncing, running.scope == scope {
            try await running.task.value
            if !force { return }
        }
        guard force || syncedScope != scope else { return }
        let task = Task { [syncPacks] in try await syncPacks(scope.accountRef) }
        syncing = (scope, task)
        isSyncing = true
        defer {
            if syncing?.task == task {
                syncing = nil
                isSyncing = false
            }
        }
        try await task.value
        guard currentScope() == scope else { return }
        syncedScope = scope
        await reloadInstalled()
    }

    func discover(search: String?) async throws -> [StickerPackFfi] {
        guard let scope = currentScope() else { throw CancellationError() }
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = try await packs(scope.accountRef, false, query?.isEmpty == false ? query : nil)
        guard currentScope() == scope else { throw CancellationError() }
        return StickerPackPresentation.discoverable(found, installed: installedCoordinates)
    }

    func lookUp(_ input: String) async throws -> StickerPackFfi {
        guard let scope = currentScope() else { throw CancellationError() }
        let pack = try await fetchPack(scope.accountRef, input)
        guard currentScope() == scope else { throw CancellationError() }
        return pack
    }

    func install(_ pack: StickerPackFfi) async throws {
        guard let scope = currentScope() else { throw CancellationError() }
        _ = try await install(scope.accountRef, pack.coordinate)
        guard currentScope() == scope else { return }
        await reloadInstalled()
    }

    func uninstall(_ pack: StickerPackFfi) async throws {
        guard let scope = currentScope() else { throw CancellationError() }
        try await uninstall(scope.accountRef, pack.coordinate)
        guard currentScope() == scope else { return }
        await reloadInstalled()
    }

    private func currentScope() -> StickerScope? {
        let current = scopeProvider()
        if current != scope {
            scope = current
            installed = []
            installedCoordinates = []
            hasLoadedInstalled = false
            loadingInstalled?.cancel()
            loadingInstalled = nil
        }
        return current
    }
}

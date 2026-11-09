import Foundation
import MarmotKit
import Observation
import UIKit

// NIP-51 emoji sets (kind 30030) are public Nostr events listing NIP-30
// shortcodes and image URLs. Browsing them is text only. Opening a set
// previews its images and installing downloads every image once; both reveal
// this device's IP address to the hosts the set's author chose, so neither
// happens until the person opens or installs a set. Installed bytes live in
// MDK; sending one re-encrypts it into the chat like any custom emoji.

/// The account and runtime emoji-set state is read under.
nonisolated struct EmojiSetScope: Hashable, Sendable {
    let accountRef: String
    let runtimeGeneration: Int
}

nonisolated enum EmojiSetPresentation {
    static func title(_ set: EmojiSetFfi) -> String {
        title(raw: set.title, identifier: set.identifier)
    }

    /// A picker section title for an installed emoji's set.
    static func title(_ emoji: InstalledCustomEmojiFfi) -> String {
        title(raw: emoji.setTitle, identifier: nil)
    }

    private static func title(raw: String?, identifier: String?) -> String {
        for candidate in [raw, identifier] {
            let text = ContentSanitizer.messageBody(candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(80)) }
        }
        return L10n.string("Emoji Set")
    }

    static func description(_ set: EmojiSetFfi) -> String? {
        let text = ContentSanitizer.messageBody(set.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }

    static func summary(_ set: EmojiSetFfi) -> String {
        L10n.plural("%lld emoji", Int64(set.emoji.count))
    }

    /// Entries MDK set aside (bad shortcode or URL, duplicates, over the cap,
    /// failed downloads). Nil when every entry is usable.
    static func skippedNote(_ set: EmojiSetFfi) -> String? {
        let count = max(Int(set.skippedCount), set.skipped.count)
        guard count > 0 else { return nil }
        return L10n.plural("%lld emoji in this set can’t be used.", Int64(count))
    }

    /// Emoji in the set whose shortcode chat messages can't carry; they stay
    /// installed but are left out of the picker.
    static func unsendableCount(_ set: EmojiSetFfi) -> Int {
        set.emoji.count { shortcode in
            guard let parsed = CustomEmojiShortcode(shortcode.shortcode) else { return true }
            return !CustomEmojiSendPolicy.isSendable(parsed)
        }
    }

    /// A pasted coordinate or `naddr`, trimmed and bounded. MDK validates it.
    static func lookupInput(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048 else { return nil }
        return trimmed
    }

    /// Whether a search names an author, which MDK can fetch from relays
    /// rather than only filter what is already stored. Only a complete,
    /// checksummed npub counts, so typing one doesn't fetch at each keystroke.
    static func searchNamesAuthor(_ search: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("npub1") {
            return trimmed.utf8.count <= 100 && NostrProfileReference.pubkeyHex(fromBech32: trimmed) != nil
        }
        return trimmed.utf8.count == 64 && trimmed.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Sets to offer: not installed and with at least one usable emoji.
    static func discoverable(_ sets: [EmojiSetFfi], installed: Set<String>) -> [EmojiSetFfi] {
        sets.filter { $0.installed == nil && !installed.contains($0.coordinate) && !$0.emoji.isEmpty }
    }

    /// Sets the account's public emoji list (kind 10030) names that aren't
    /// installed here yet, in list order.
    static func suggestions(_ list: UserEmojiListFfi, installed: Set<String>) -> [EmojiSetFfi] {
        var seen = Set<String>()
        return discoverable(list.sets, installed: installed).filter { seen.insert($0.coordinate).inserted }
    }

    enum Action: Equatable {
        case install
        /// A newer version than the installed one is stored.
        case update
        case remove
    }

    /// `isInstalled` is the library's live answer; the set's own state can
    /// be stale after an uninstall elsewhere.
    static func action(for set: EmojiSetFfi, isInstalled: Bool) -> Action {
        guard isInstalled else { return .install }
        return set.installed?.updateAvailable == true ? .update : .remove
    }

    /// Install progress, or nil while MDK hasn't counted the set yet.
    static func fraction(_ progress: EmojiSetInstallProgressFfi) -> Double? {
        guard progress.totalEmoji > 0 else { return nil }
        return min(1, Double(progress.completedEmoji) / Double(progress.totalEmoji))
    }

    /// A cancelled install is the person's own choice, not an error to show.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? MarmotKitError, case .EmojiSetInstallCancelled = error { return true }
        return false
    }

    /// The version MDK says is stored now when the shown one went stale.
    static func changedVersion(_ error: Error) -> String? {
        guard let error = error as? MarmotKitError, case .EmojiSetChanged(let current) = error else { return nil }
        return current
    }

    /// The upload file extension for an installed emoji's validated MIME type.
    static func fileExtension(mime: String) -> String {
        switch mime.lowercased() {
        case "image/png", "image/apng": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/jpeg", "image/jpg": "jpg"
        default: "img"
        }
    }

    /// Picker groups for installed emoji, one per set in install order.
    struct PickerGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let emoji: [CustomEmojiSendable]
    }

    static func pickerGroups(_ sendables: [CustomEmojiSendable]) -> (other: [CustomEmojiSendable], sets: [PickerGroup]) {
        var other: [CustomEmojiSendable] = []
        var order: [String] = []
        var titles: [String: String] = [:]
        var members: [String: [CustomEmojiSendable]] = [:]
        for sendable in sendables {
            guard case .installed(let emoji) = sendable.artwork else {
                other.append(sendable)
                continue
            }
            if members[emoji.setCoordinate] == nil {
                order.append(emoji.setCoordinate)
                titles[emoji.setCoordinate] = title(emoji)
            }
            members[emoji.setCoordinate, default: []].append(sendable)
        }
        let sets = order.map { PickerGroup(id: $0, title: titles[$0] ?? "", emoji: members[$0] ?? []) }
        return (other, sets)
    }
}

/// MDK's emoji-set calls, injected so the library is testable without a runtime.
struct EmojiSetCalls {
    var sets: @MainActor (_ accountRef: String, _ installedOnly: Bool, _ search: String?) async throws -> [EmojiSetFfi]
    var set: @MainActor (_ accountRef: String, _ coordinate: String) async throws -> EmojiSetFfi?
    var sync: @MainActor (_ accountRef: String, _ search: String?) async throws -> Void
    var fetch: @MainActor (_ accountRef: String, _ input: String) async throws -> EmojiSetFfi
    var install: @MainActor (_ accountRef: String, _ coordinate: String, _ eventIdHex: String,
                             _ control: EmojiSetInstallControlFfi) async throws -> EmojiSetInstallResultFfi
    var uninstall: @MainActor (_ accountRef: String, _ coordinate: String) async throws -> Bool
    var installedEmoji: @MainActor (_ accountRef: String) async throws -> [InstalledCustomEmojiFfi]
    var readInstalled: @MainActor (_ accountRef: String, _ coordinate: String, _ shortcode: String) async throws -> Data
    var fetchPreview: @MainActor (_ accountRef: String, _ coordinate: String, _ eventIdHex: String,
                                  _ shortcode: String) async throws -> Data
    var userList: @MainActor (_ accountRef: String) async throws -> UserEmojiListFfi

    static func live(client: @escaping @MainActor () throws -> MarmotClient) -> EmojiSetCalls {
        EmojiSetCalls(
            sets: { try await client().emojiSets(accountRef: $0, installedOnly: $1, search: $2, limit: 200) },
            set: { try await client().emojiSet(accountRef: $0, coordinate: $1) },
            sync: { _ = try await client().syncEmojiSets(accountRef: $0, search: $1) },
            fetch: { try await client().fetchEmojiSet(accountRef: $0, input: $1) },
            install: { try await client().installEmojiSet(accountRef: $0, coordinate: $1, expectedEventIdHex: $2, control: $3) },
            uninstall: { try await client().uninstallEmojiSet(accountRef: $0, coordinate: $1) },
            installedEmoji: { try await client().installedCustomEmoji(accountRef: $0) },
            readInstalled: { try await client().readInstalledCustomEmoji(accountRef: $0, coordinate: $1, shortcode: $2).bytes },
            fetchPreview: {
                try await client().fetchEmojiSetAsset(accountRef: $0, coordinate: $1, expectedEventIdHex: $2, shortcode: $3).bytes
            },
            userList: { try await client().userEmojiList(accountRef: $0) }
        )
    }
}

/// The account's emoji sets: installed sets and emoji for the pickers and
/// composer, discovery for the browser, and installs in progress. Owned by
/// `AppState` so typed `:shortcode:` resolves in every chat; reset whenever
/// the account or runtime changes.
@Observable
@MainActor
final class EmojiSetLibrary {
    typealias Decode = @MainActor (Data, Int, CGFloat) async -> UIImage?

    private(set) var installedSets: [EmojiSetFfi] = []
    /// Installed emoji in MDK's order: set install order, then set order.
    private(set) var installedEmoji: [InstalledCustomEmojiFfi] = []
    private(set) var hasLoadedInstalled = false
    private(set) var isSyncing = false
    /// Installs in progress, by set coordinate.
    private(set) var installProgress: [String: EmojiSetInstallProgressFfi] = [:]

    @ObservationIgnored private let scopeProvider: @MainActor () -> EmojiSetScope?
    @ObservationIgnored private let calls: EmojiSetCalls
    @ObservationIgnored private let makeControl: @MainActor () -> EmojiSetInstallControlFfi
    @ObservationIgnored private let progressInterval: Duration
    @ObservationIgnored let images: EmojiSetImageStore
    @ObservationIgnored private var scope: EmojiSetScope?
    @ObservationIgnored private var loadingInstalled: Task<Void, Never>?
    @ObservationIgnored private var syncedScope: EmojiSetScope?
    @ObservationIgnored private var syncing: (scope: EmojiSetScope, task: Task<Void, Error>)?
    @ObservationIgnored private var controls: [String: EmojiSetInstallControlFfi] = [:]

    init(
        scopeProvider: @escaping @MainActor () -> EmojiSetScope?,
        calls: EmojiSetCalls,
        makeControl: @escaping @MainActor () -> EmojiSetInstallControlFfi = { EmojiSetInstallControlFfi() },
        progressInterval: Duration = .milliseconds(200),
        decode: @escaping Decode = { data, pixelSize, scale in
            await MessageMediaThumbnailDecoder.image(data: data, maxPixelSize: pixelSize, scale: scale)
        }
    ) {
        self.scopeProvider = scopeProvider
        self.calls = calls
        self.makeControl = makeControl
        self.progressInterval = progressInterval
        images = EmojiSetImageStore(scopeProvider: scopeProvider, calls: calls, decode: decode)
    }

    /// Read-only, so a view body can ask without changing observed state.
    /// Reads observed state before the unobserved scope check, so a view
    /// body that asks before the first load still updates after it.
    func isInstalled(_ coordinate: String) -> Bool {
        let contains = installedSets.contains { $0.coordinate == coordinate }
        return contains && scopeProvider() == scope
    }

    /// Installed emoji for the current scope; empty until loaded.
    var currentInstalledEmoji: [InstalledCustomEmojiFfi] {
        let emoji = installedEmoji
        return scopeProvider() == scope ? emoji : []
    }

    func loadInstalledIfNeeded() async {
        guard currentScope() != nil, !hasLoadedInstalled else { return }
        if let loadingInstalled { return await loadingInstalled.value }
        let task = Task { await reloadInstalled() }
        loadingInstalled = task
        await task.value
        loadingInstalled = nil
    }

    /// Re-reads installed sets and emoji. Local only. A failed read keeps
    /// what is on screen.
    func reloadInstalled() async {
        guard let scope = currentScope() else { return }
        do {
            async let sets = calls.sets(scope.accountRef, true, nil)
            async let emoji = calls.installedEmoji(scope.accountRef)
            let (loadedSets, loadedEmoji) = try await (sets, emoji)
            guard currentScope() == scope else { return }
            installedSets = loadedSets
            installedEmoji = loadedEmoji
            hasLoadedInstalled = true
        } catch {
            return
        }
    }

    /// Fetches the newest sets from relays (text only), once per account and
    /// runtime unless forced. A search naming an author always fetches that
    /// author's sets. A caller arriving mid-sync shares its outcome.
    func sync(force: Bool = false, search: String? = nil) async throws {
        guard let scope = currentScope() else { return }
        if let search, EmojiSetPresentation.searchNamesAuthor(search) {
            try await calls.sync(scope.accountRef, search.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if let running = syncing, running.scope == scope {
            try await running.task.value
            if !force { return }
        }
        guard force || syncedScope != scope else { return }
        let task = Task { [calls] in try await calls.sync(scope.accountRef, nil) }
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

    func discover(search: String?) async throws -> [EmojiSetFfi] {
        guard let scope = currentScope() else { throw CancellationError() }
        let query = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = try await calls.sets(scope.accountRef, false, query?.isEmpty == false ? query : nil)
        guard currentScope() == scope else { throw CancellationError() }
        return EmojiSetPresentation.discoverable(found, installed: Set(installedSets.map(\.coordinate)))
    }

    /// Sets the account's own emoji list points to. Text only.
    func suggestions() async throws -> [EmojiSetFfi] {
        guard let scope = currentScope() else { throw CancellationError() }
        let list = try await calls.userList(scope.accountRef)
        guard currentScope() == scope else { throw CancellationError() }
        return EmojiSetPresentation.suggestions(list, installed: Set(installedSets.map(\.coordinate)))
    }

    func lookUp(_ input: String) async throws -> EmojiSetFfi {
        guard let scope = currentScope() else { throw CancellationError() }
        let set = try await calls.fetch(scope.accountRef, input)
        guard currentScope() == scope else { throw CancellationError() }
        return set
    }

    /// The stored version of a set now, for a screen whose copy went stale.
    func current(_ coordinate: String) async throws -> EmojiSetFfi? {
        guard let scope = currentScope() else { throw CancellationError() }
        let set = try await calls.set(scope.accountRef, coordinate)
        guard currentScope() == scope else { throw CancellationError() }
        return set
    }

    /// Downloads and stores the version shown (`set.eventIdHex`), also to
    /// apply an update. Progress is published in `installProgress`.
    @discardableResult
    func install(_ set: EmojiSetFfi) async throws -> EmojiSetInstallResultFfi {
        guard let scope = currentScope() else { throw CancellationError() }
        let coordinate = set.coordinate
        guard controls[coordinate] == nil else { throw CancellationError() }
        let control = makeControl()
        controls[coordinate] = control
        installProgress[coordinate] = EmojiSetInstallProgressFfi(
            completedEmoji: 0, totalEmoji: UInt32(clamping: set.emoji.count), transferredBytes: 0)
        let interval = progressInterval
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.controls[coordinate] === control else { return }
                self.installProgress[coordinate] = control.progress()
            }
        }
        defer {
            poll.cancel()
            if controls[coordinate] === control {
                controls[coordinate] = nil
                installProgress[coordinate] = nil
            }
        }
        let result = try await calls.install(scope.accountRef, coordinate, set.eventIdHex, control)
        guard currentScope() == scope else { throw CancellationError() }
        await reloadInstalled()
        return result
    }

    func cancelInstall(_ coordinate: String) {
        controls[coordinate]?.cancel()
    }

    func uninstall(_ coordinate: String) async throws {
        guard let scope = currentScope() else { throw CancellationError() }
        _ = try await calls.uninstall(scope.accountRef, coordinate)
        guard currentScope() == scope else { return }
        images.forget(setCoordinate: coordinate)
        await reloadInstalled()
    }

    private func currentScope() -> EmojiSetScope? {
        let current = scopeProvider()
        if current != scope {
            scope = current
            installedSets = []
            installedEmoji = []
            hasLoadedInstalled = false
            loadingInstalled?.cancel()
            loadingInstalled = nil
            for control in controls.values { control.cancel() }
            controls.removeAll()
            installProgress.removeAll()
        }
        return current
    }
}

/// Decoded emoji-set images: installed emoji read from MDK's local store,
/// and previews of a set the person opened. Bounded, scoped to one account
/// and runtime, and a failed load stays failed until an explicit retry, so
/// scrolling never re-dials a broken host.
@MainActor
final class EmojiSetImageStore {
    enum Source: Hashable {
        case installed(coordinate: String, shortcode: String, sha256: String)
        case preview(coordinate: String, eventIdHex: String, shortcode: String)

        var coordinate: String {
            switch self {
            case .installed(let coordinate, _, _), .preview(let coordinate, _, _): coordinate
            }
        }
    }

    private struct Key: Hashable {
        let scope: EmojiSetScope
        let source: Source
        let pixelSize: Int
    }

    static let limit = 256

    private let scopeProvider: @MainActor () -> EmojiSetScope?
    private let calls: EmojiSetCalls
    private let decode: EmojiSetLibrary.Decode
    private var scope: EmojiSetScope?
    private var images: [Key: UIImage] = [:]
    private var order: [Key] = []
    private var failures: Set<Key> = []
    private var inFlight: [Key: Task<UIImage?, Never>] = [:]

    init(scopeProvider: @escaping @MainActor () -> EmojiSetScope?, calls: EmojiSetCalls, decode: @escaping EmojiSetLibrary.Decode) {
        self.scopeProvider = scopeProvider
        self.calls = calls
        self.decode = decode
    }

    func cached(_ source: Source, pixelSize: Int) -> UIImage? {
        guard let scope = syncedScope() else { return nil }
        return images[Key(scope: scope, source: source, pixelSize: pixelSize)]
    }

    func hasFailed(_ source: Source, pixelSize: Int) -> Bool {
        guard let scope = syncedScope() else { return false }
        return failures.contains(Key(scope: scope, source: source, pixelSize: pixelSize))
    }

    func image(for source: Source, pixelSize: Int, scale: CGFloat) async -> UIImage? {
        guard let scope = syncedScope() else { return nil }
        let key = Key(scope: scope, source: source, pixelSize: pixelSize)
        if let cached = images[key] { return cached }
        guard !failures.contains(key) else { return nil }
        let task = inFlight[key] ?? Task { [calls, decode] in
            do {
                let data = switch source {
                case .installed(let coordinate, let shortcode, _):
                    try await calls.readInstalled(scope.accountRef, coordinate, shortcode)
                case .preview(let coordinate, let eventIdHex, let shortcode):
                    try await calls.fetchPreview(scope.accountRef, coordinate, eventIdHex, shortcode)
                }
                return await decode(data, pixelSize, scale)
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        if inFlight[key] == task { inFlight[key] = nil }
        guard scopeProvider() == key.scope else { return nil }
        if let image {
            if images.updateValue(image, forKey: key) == nil { order.append(key) }
            while order.count > Self.limit { images[order.removeFirst()] = nil }
        } else {
            failures.insert(key)
        }
        return image
    }

    /// Clears an earlier failure and loads again, for an explicit tap.
    func retry(_ source: Source, pixelSize: Int, scale: CGFloat) async -> UIImage? {
        guard let scope = syncedScope() else { return nil }
        failures.remove(Key(scope: scope, source: source, pixelSize: pixelSize))
        return await image(for: source, pixelSize: pixelSize, scale: scale)
    }

    /// Drops a removed set's images so a reinstall reads fresh bytes.
    func forget(setCoordinate: String) {
        images = images.filter { $0.key.source.coordinate != setCoordinate }
        order.removeAll { $0.source.coordinate == setCoordinate }
        failures = failures.filter { $0.source.coordinate != setCoordinate }
    }

    private func syncedScope() -> EmojiSetScope? {
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

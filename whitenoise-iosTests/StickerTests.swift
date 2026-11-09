import Foundation
import Testing
import UIKit
import MarmotKit
@testable import whitenoise_ios

struct StickerPresentationTests {
    @Test func receivedStickersLoadByThemselvesOnlyFromInstalledPacksWhenPhotosMay() {
        #expect(StickerLoadPolicy.loadsAutomatically(isFromMe: true, packInstalled: false, autoDownloadImages: false))
        #expect(StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: true, autoDownloadImages: true))
        #expect(!StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: true, autoDownloadImages: false))
        #expect(!StickerLoadPolicy.loadsAutomatically(isFromMe: false, packInstalled: false, autoDownloadImages: true))
    }

    @Test func labelsUseOnlyAShortEmojiAndSanitizeDescriptions() {
        let generic = StickerLoadPolicy.label(emoji: nil)
        #expect(!generic.isEmpty)
        #expect(StickerLoadPolicy.label(emoji: "😀").contains("😀"))
        #expect(StickerLoadPolicy.label(emoji: "not an emoji") == generic)
        #expect(StickerLoadPolicy.label(emoji: String(repeating: "😀", count: 20)) == generic)

        let long = StickerLoadPolicy.accessibilityLabel(alt: String(repeating: "a", count: 500), emoji: nil)
        #expect(long.count < 200)
        #expect(!StickerLoadPolicy.accessibilityLabel(alt: "cat\u{202E}waving", emoji: nil).contains("\u{202E}"))
        #expect(StickerLoadPolicy.accessibilityLabel(alt: "  ", emoji: nil) == generic)
    }

    @Test func discoveryLeavesOutInstalledAndEmptyPacks() {
        let installed = stickerPack("mine", installed: true)
        let listedElsewhere = stickerPack("other")
        let empty = stickerPack("empty", stickers: [])
        let fresh = stickerPack("fresh")
        let found = StickerPackPresentation.discoverable([installed, listedElsewhere, empty, fresh],
                                                         installed: [listedElsewhere.coordinate])
        #expect(found.map(\.coordinate) == [fresh.coordinate])
    }

    @Test func aFailedRefreshNeverReadsAsNoPacks() {
        typealias P = StickerPackPresentation
        #expect(P.discoveryState(isLoading: false, packCount: 0, search: "", syncError: "offline")
                == .unreachable(message: "offline"))
        #expect(P.discoveryState(isLoading: false, packCount: 0, search: "", syncError: nil) == .noneOnRelays)
        #expect(P.discoveryState(isLoading: false, packCount: 0, search: " cats ", syncError: nil) == .noMatches)
        #expect(P.discoveryState(isLoading: true, packCount: 0, search: "", syncError: nil) == .loading)
        // Cached packs stay listed while loading or after a failed refresh.
        #expect(P.discoveryState(isLoading: true, packCount: 2, search: "", syncError: "offline") == .packs)
    }

    @Test func lookupInputIsTrimmedAndBounded() {
        #expect(StickerPackPresentation.lookupInput("  naddr1abc \n") == "naddr1abc")
        #expect(StickerPackPresentation.lookupInput("   ") == nil)
        #expect(StickerPackPresentation.lookupInput(String(repeating: "a", count: 5_000)) == nil)
    }

    @Test func packTextIsSanitizedAndBounded() {
        #expect(StickerPackPresentation.title(stickerPack(title: "  ")) == StickerPackPresentation.title(stickerPack(title: "")))
        #expect(!StickerPackPresentation.title(stickerPack(title: "")).isEmpty)
        #expect(StickerPackPresentation.title(stickerPack(title: String(repeating: "x", count: 300))).count <= 80)
        var pack = stickerPack()
        pack.description = "  "
        #expect(StickerPackPresentation.description(pack) == nil)
        pack.description = String(repeating: "d", count: 2_000)
        #expect((StickerPackPresentation.description(pack)?.count ?? 0) <= 500)
    }
}

@MainActor
struct StickerAssetStoreTests {
    @MainActor final class Harness {
        var scope: StickerScope? = StickerScope(accountRef: "alice", runtimeGeneration: 1)
        var fetches: [(String, StickerRefFfi)] = []
        var fetchError: Error?
        var decodeSucceeds = true
        var gate: CheckedContinuation<Void, Never>?
        var holds = false

        lazy var store = StickerAssetStore(
            scopeProvider: { [weak self] in self?.scope },
            fetch: { [weak self] accountRef, ref in
                guard let self else { throw CancellationError() }
                self.fetches.append((accountRef, ref))
                if self.holds { await withCheckedContinuation { self.gate = $0 } }
                if let error = self.fetchError { throw error }
                return StickerAssetFfi(sticker: sticker(ref.shortcode, pack: ref.packCoordinate, sha: ref.plaintextSha256),
                                       bytes: Data("png".utf8))
            },
            decode: { [weak self] _, _ in
                guard self?.decodeSucceeds == true else { return nil }
                return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
            }
        )
    }

    let wave = StickerKey(sticker("wave"))

    @Test func loadedImagesAreCachedPerAccount() async throws {
        let harness = Harness()
        let first = try #require(await harness.store.image(for: wave))
        #expect(first.sticker.shortcode == "wave")
        #expect(harness.store.cached(wave)?.image === first.image)
        _ = await harness.store.image(for: wave)
        #expect(harness.fetches.count == 1)
        #expect(harness.fetches.first?.0 == "alice")
        #expect(harness.fetches.first?.1 == wave.ref)

        harness.scope = StickerScope(accountRef: "bob", runtimeGeneration: 1)
        #expect(harness.store.cached(wave) == nil)
        _ = await harness.store.image(for: wave)
        #expect(harness.fetches.last?.0 == "bob")
    }

    @Test func aFailureIsNotRetriedUntilAnExplicitRetry() async {
        let harness = Harness()
        harness.fetchError = MarmotKitError.StickerNetwork(details: "offline")
        #expect(await harness.store.image(for: wave) == nil)
        #expect(harness.store.hasFailed(wave))
        #expect(await harness.store.image(for: wave) == nil)
        #expect(harness.fetches.count == 1)

        harness.fetchError = nil
        #expect(await harness.store.retry(wave) != nil)
        #expect(harness.fetches.count == 2)
        #expect(!harness.store.hasFailed(wave))
    }

    @Test func undecodableBytesCountAsAFailure() async {
        let harness = Harness()
        harness.decodeSucceeds = false
        #expect(await harness.store.image(for: wave) == nil)
        #expect(harness.store.hasFailed(wave))
    }

    @Test func concurrentRequestsShareOneDownload() async throws {
        let harness = Harness()
        harness.holds = true
        async let first = harness.store.image(for: wave)
        async let second = harness.store.image(for: wave)
        try await eventually { harness.gate != nil }
        harness.gate?.resume()
        let results = await [first, second]
        #expect(results.allSatisfy { $0 != nil })
        #expect(harness.fetches.count == 1)
    }

    @Test func aResultArrivingAfterAnAccountSwitchIsDropped() async throws {
        let harness = Harness()
        harness.holds = true
        async let result = harness.store.image(for: wave)
        try await eventually { harness.gate != nil }
        harness.scope = StickerScope(accountRef: "bob", runtimeGeneration: 1)
        harness.gate?.resume()
        #expect(await result == nil)
        #expect(harness.store.cached(wave) == nil)
        #expect(!harness.store.hasFailed(wave))
    }
}

@MainActor
struct StickerLibraryTests {
    @MainActor final class Harness {
        var scope: StickerScope? = StickerScope(accountRef: "alice", runtimeGeneration: 1)
        var installed: [StickerPackFfi] = [stickerPack("mine", installed: true)]
        var discovered: [StickerPackFfi] = [stickerPack("fresh")]
        var syncs = 0
        var syncError: Error?
        var syncGate: CheckedContinuation<Void, Never>?
        var holdsSync = false
        var reads = 0
        var installs: [String] = []
        var uninstalls: [String] = []

        lazy var library = StickerLibrary(
            scopeProvider: { [weak self] in self?.scope },
            packs: { [weak self] _, installedOnly, _ in
                guard let self else { return [] }
                self.reads += 1
                return installedOnly ? self.installed : self.installed + self.discovered
            },
            sync: { [weak self] _ in
                guard let self else { return }
                self.syncs += 1
                if self.holdsSync { await withCheckedContinuation { self.syncGate = $0 } }
                if let error = self.syncError { throw error }
            },
            fetchPack: { _, _ in stickerPack("linked") },
            install: { [weak self] _, input in
                guard let self else { throw CancellationError() }
                self.installs.append(input)
                var pack = self.discovered.first { $0.coordinate == input } ?? stickerPack("linked")
                pack.installed = true
                self.installed.append(pack)
                return pack
            },
            uninstall: { [weak self] _, input in
                self?.uninstalls.append(input)
                self?.installed.removeAll { $0.coordinate == input }
            }
        )
    }

    @Test func installedPacksLoadOncePerAccount() async {
        let harness = Harness()
        let mine = harness.installed[0].coordinate
        #expect(!harness.library.isInstalled(mine))
        await harness.library.loadInstalledIfNeeded()
        await harness.library.loadInstalledIfNeeded()
        #expect(harness.reads == 1)
        #expect(harness.library.isInstalled(mine))

        harness.scope = StickerScope(accountRef: "bob", runtimeGeneration: 1)
        #expect(!harness.library.isInstalled(mine))
        await harness.library.loadInstalledIfNeeded()
        #expect(harness.reads == 2)
    }

    @Test func syncRunsOncePerAccountUnlessForced() async throws {
        let harness = Harness()
        try await harness.library.sync()
        try await harness.library.sync()
        #expect(harness.syncs == 1)
        try await harness.library.sync(force: true)
        #expect(harness.syncs == 2)
    }

    @Test func aCallerArrivingMidSyncWaitsForItsOutcome() async throws {
        let harness = Harness()
        harness.holdsSync = true
        harness.syncError = MarmotKitError.StickerNetwork(details: "offline")
        let library = harness.library
        let first = Task { try await library.sync() }
        try await eventually { harness.syncGate != nil }
        let second = Task { try await library.sync() }
        await Task.yield()
        harness.syncGate?.resume()
        await #expect(throws: MarmotKitError.self) { try await first.value }
        await #expect(throws: MarmotKitError.self) { try await second.value }
        #expect(harness.syncs == 1)

        // A failed sync is retried by the next caller.
        harness.holdsSync = false
        harness.syncError = nil
        try await harness.library.sync()
        #expect(harness.syncs == 2)
    }

    @Test func installAndUninstallUpdateTheInstalledList() async throws {
        let harness = Harness()
        await harness.library.loadInstalledIfNeeded()
        let fresh = try #require(try await harness.library.discover(search: nil).first)
        #expect(!harness.library.installed.contains { $0.coordinate == fresh.coordinate })

        try await harness.library.install(fresh)
        #expect(harness.installs == [fresh.coordinate])
        #expect(harness.library.isInstalled(fresh.coordinate))
        #expect(try await harness.library.discover(search: nil).isEmpty)

        try await harness.library.uninstall(fresh)
        #expect(harness.uninstalls == [fresh.coordinate])
        #expect(!harness.library.isInstalled(fresh.coordinate))
    }
}

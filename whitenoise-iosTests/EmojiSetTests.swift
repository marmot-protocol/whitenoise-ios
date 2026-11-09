import Foundation
import Synchronization
import Testing
import UIKit
import MarmotKit
@testable import whitenoise_ios

struct EmojiSetPresentationTests {
    @Test func discoveryLeavesOutInstalledAndEmptySets() {
        let installedHere = emojiSet("mine", installed: installedEmojiSetState())
        let installedElsewhere = emojiSet("listed")
        let empty = emojiSet("empty", emoji: [])
        let fresh = emojiSet("fresh")
        let shown = EmojiSetPresentation.discoverable([installedHere, installedElsewhere, empty, fresh],
                                                      installed: [installedElsewhere.coordinate])
        #expect(shown.map(\.identifier) == ["fresh"])
    }

    @Test func emojiListSuggestionsSkipInstalledAndRepeatedSets() {
        let fresh = emojiSet("fresh")
        let mine = emojiSet("mine")
        let list = UserEmojiListFfi(eventIdHex: nil, createdAt: nil, ownEmoji: nil, sets: [fresh, mine, fresh],
                                    missingSetCoordinates: [], complete: true)
        #expect(EmojiSetPresentation.suggestions(list, installed: [mine.coordinate]).map(\.identifier) == ["fresh"])
    }

    @Test func theActionFollowsTheLibraryNotAStaleCopy() {
        let installed = emojiSet(installed: installedEmojiSetState())
        let outdated = emojiSet(installed: installedEmojiSetState(updateAvailable: true))
        #expect(EmojiSetPresentation.action(for: emojiSet(), isInstalled: false) == .install)
        #expect(EmojiSetPresentation.action(for: installed, isInstalled: true) == .remove)
        #expect(EmojiSetPresentation.action(for: outdated, isInstalled: true) == .update)
        // Removed since this copy was read.
        #expect(EmojiSetPresentation.action(for: outdated, isInstalled: false) == .install)
    }

    @Test func progressIsUnknownUntilMdkCountsTheSet() {
        #expect(EmojiSetPresentation.fraction(EmojiSetInstallProgressFfi(completedEmoji: 0, totalEmoji: 0, transferredBytes: 0)) == nil)
        let half = EmojiSetPresentation.fraction(EmojiSetInstallProgressFfi(completedEmoji: 3, totalEmoji: 6, transferredBytes: 9))
        #expect(half == 0.5)
        let over = EmojiSetPresentation.fraction(EmojiSetInstallProgressFfi(completedEmoji: 9, totalEmoji: 6, transferredBytes: 9))
        #expect(over == 1)
    }

    @Test func setTextIsSanitizedBoundedAndNeverBlank() {
        let long = emojiSet(title: String(repeating: "a", count: 500))
        #expect(EmojiSetPresentation.title(long).count <= 80)
        #expect(!EmojiSetPresentation.title(emojiSet(title: "Blobs\u{202E}")).contains("\u{202E}"))
        #expect(EmojiSetPresentation.title(emojiSet("blobcats", title: "  ")) == "blobcats")
        #expect(!EmojiSetPresentation.title(installedEmoji("wave", title: nil)).isEmpty)
        var described = emojiSet()
        described.description = "   "
        #expect(EmojiSetPresentation.description(described) == nil)
    }

    @Test func notesExplainSkippedAndUnsendableEmoji() {
        var set = emojiSet(emoji: ["ok", "has-hyphen", String(repeating: "x", count: 63)])
        #expect(EmojiSetPresentation.skippedNote(set) == nil)
        #expect(EmojiSetPresentation.unsendableCount(set) == 2)
        set.skippedCount = 2
        #expect(EmojiSetPresentation.skippedNote(set) != nil)
    }

    @Test func onlyAuthorSearchesFetchFromRelays() throws {
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("ab")))
        #expect(EmojiSetPresentation.searchNamesAuthor(" \(npub) "))
        // A partial npub, still being typed, filters locally.
        #expect(!EmojiSetPresentation.searchNamesAuthor(String(npub.prefix(12))))
        #expect(EmojiSetPresentation.searchNamesAuthor(" \(hex("ab").uppercased()) "))
        #expect(!EmojiSetPresentation.searchNamesAuthor("blob cats"))
        #expect(!EmojiSetPresentation.searchNamesAuthor(String(repeating: "g", count: 64)))
        #expect(!EmojiSetPresentation.searchNamesAuthor("npub1" + String(repeating: "q", count: 200)))
    }

    @Test func cancellingAnInstallIsNotAnError() {
        #expect(EmojiSetPresentation.isCancellation(MarmotKitError.EmojiSetInstallCancelled))
        #expect(EmojiSetPresentation.isCancellation(CancellationError()))
        #expect(!EmojiSetPresentation.isCancellation(MarmotKitError.EmojiSetNotFound))
        #expect(EmojiSetPresentation.changedVersion(MarmotKitError.EmojiSetChanged(currentEventIdHex: "new")) == "new")
        #expect(EmojiSetPresentation.changedVersion(MarmotKitError.EmojiSetNotFound) == nil)
    }

    @Test func pickerGroupsInstalledEmojiBySetInInstallOrder() throws {
        let chat = try #require(CustomEmojiBuiltins.all.first.map(CustomEmojiSendable.init(builtin:)))
        let sendables = try [
            chat,
            #require(CustomEmojiSendable(installed: installedEmoji("a", set: "second", title: "Second"))),
            #require(CustomEmojiSendable(installed: installedEmoji("b", set: "first", title: "First"))),
            #require(CustomEmojiSendable(installed: installedEmoji("c", set: "second", title: "Second"))),
        ]
        let groups = EmojiSetPresentation.pickerGroups(sendables)
        #expect(groups.other.map(\.id) == [chat.id])
        #expect(groups.sets.map(\.title) == ["Second", "First"])
        #expect(groups.sets.first?.emoji.map(\.id) == ["a", "c"])
    }
}

@MainActor
struct EmojiSetLibraryTests {
    @MainActor final class Harness {
        var scope: EmojiSetScope? = EmojiSetScope(accountRef: "alice", runtimeGeneration: 1)
        var installedSets: [EmojiSetFfi] = [emojiSet("mine", installed: installedEmojiSetState())]
        var discovered: [EmojiSetFfi] = [emojiSet("fresh")]
        var syncs: [String?] = []
        var reads = 0
        var installs: [(coordinate: String, eventIdHex: String)] = []
        var uninstalls: [String] = []
        var installGate: CheckedContinuation<Void, Never>?
        var holdsInstall = false
        var lastControl: EmojiSetInstallControlFfi?
        var previewFetches = 0
        var previewError: Error?
        var localReads = 0

        var calls: EmojiSetCalls {
            EmojiSetCalls(
                sets: { [weak self] _, installedOnly, _ in
                    guard let self else { throw CancellationError() }
                    self.reads += 1
                    return installedOnly ? self.installedSets : self.installedSets + self.discovered
                },
                set: { [weak self] _, coordinate in
                    guard let self else { throw CancellationError() }
                    return (self.installedSets + self.discovered).first { $0.coordinate == coordinate }
                },
                sync: { [weak self] _, search in self?.syncs.append(search) },
                fetch: { _, _ in emojiSet("linked") },
                install: { [weak self] _, coordinate, eventIdHex, control in
                    guard let self else { throw CancellationError() }
                    self.installs.append((coordinate, eventIdHex))
                    self.lastControl = control
                    if self.holdsInstall { await withCheckedContinuation { self.installGate = $0 } }
                    if control.isCancelled() { throw MarmotKitError.EmojiSetInstallCancelled }
                    var set = self.discovered.first { $0.coordinate == coordinate } ?? emojiSet("linked")
                    set.installed = installedEmojiSetState()
                    self.installedSets.append(set)
                    return EmojiSetInstallResultFfi(set: set, installedCount: UInt32(set.emoji.count), skipped: [])
                },
                uninstall: { [weak self] _, coordinate in
                    guard let self else { throw CancellationError() }
                    self.uninstalls.append(coordinate)
                    self.installedSets.removeAll { $0.coordinate == coordinate }
                    return true
                },
                installedEmoji: { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    return self.installedSets.flatMap { set in set.emoji.map { installedEmoji($0.shortcode, set: set.identifier) } }
                },
                readInstalled: { [weak self] _, _, _ in
                    self?.localReads += 1
                    return Data("local".utf8)
                },
                fetchPreview: { [weak self] _, _, _, _ in
                    guard let self else { throw CancellationError() }
                    self.previewFetches += 1
                    if let previewError = self.previewError { throw previewError }
                    return Data("remote".utf8)
                },
                userList: { [weak self] _ in
                    guard let self else { throw CancellationError() }
                    return UserEmojiListFfi(eventIdHex: nil, createdAt: nil, ownEmoji: nil,
                                            sets: self.installedSets + self.discovered, missingSetCoordinates: [], complete: true)
                }
            )
        }

        lazy var library = EmojiSetLibrary(
            scopeProvider: { [weak self] in self?.scope },
            calls: calls,
            progressInterval: .milliseconds(5),
            decode: { data, _, _ in data.isEmpty ? nil : UIImage() }
        )
    }

    @Test func installedEmojiLoadOncePerAccount() async {
        let harness = Harness()
        let mine = harness.installedSets[0].coordinate
        #expect(harness.library.currentInstalledEmoji.isEmpty)
        await harness.library.loadInstalledIfNeeded()
        await harness.library.loadInstalledIfNeeded()
        #expect(harness.reads == 1)
        #expect(harness.library.isInstalled(mine))
        #expect(harness.library.currentInstalledEmoji.map(\.shortcode) == ["blob_wave", "blob_nap"])

        harness.scope = EmojiSetScope(accountRef: "bob", runtimeGeneration: 1)
        #expect(!harness.library.isInstalled(mine))
        #expect(harness.library.currentInstalledEmoji.isEmpty)
        await harness.library.loadInstalledIfNeeded()
        #expect(harness.reads == 2)
    }

    @Test func aViewThatAsksBeforeTheFirstLoadIsToldWhenItLands() async {
        let harness = Harness()
        let mine = harness.installedSets[0].coordinate
        let changed = Mutex(0)
        withObservationTracking {
            _ = harness.library.isInstalled(mine)
            _ = harness.library.currentInstalledEmoji
        } onChange: {
            changed.withLock { $0 += 1 }
        }
        await harness.library.loadInstalledIfNeeded()
        #expect(changed.withLock { $0 } == 1)
        #expect(harness.library.isInstalled(mine))
    }

    @Test func browsingSyncsOncePerAccountButAuthorSearchesAlwaysFetch() async throws {
        let harness = Harness()
        try await harness.library.sync()
        try await harness.library.sync(search: "blobs")
        #expect(harness.syncs == [nil])
        let npub = try #require(NostrProfileReference.npub(fromAccountIdHex: hex("ab")))
        try await harness.library.sync(search: " \(npub) ")
        try await harness.library.sync(search: npub)
        try await harness.library.sync(search: "npub1abc")
        #expect(harness.syncs == [nil, npub, npub])
        try await harness.library.sync(force: true)
        #expect(harness.syncs.count == 4)
    }

    @Test func installPublishesProgressThenTheInstalledEmoji() async throws {
        let harness = Harness()
        harness.holdsInstall = true
        await harness.library.loadInstalledIfNeeded()
        let fresh = try #require(try await harness.library.discover(search: nil).first)
        let library = harness.library
        let install = Task { try await library.install(fresh) }
        try await eventually { harness.installGate != nil }
        #expect(library.installProgress[fresh.coordinate]?.totalEmoji == UInt32(fresh.emoji.count))
        // One install per set at a time.
        await #expect(throws: CancellationError.self) { try await library.install(fresh) }

        harness.installGate?.resume()
        _ = try await install.value
        #expect(harness.installs.map(\.eventIdHex) == [fresh.eventIdHex])
        #expect(library.installProgress.isEmpty)
        #expect(library.isInstalled(fresh.coordinate))
        #expect(Set(library.currentInstalledEmoji.map(\.setCoordinate)) == [harness.installedSets[0].coordinate, fresh.coordinate])
        #expect(try await library.discover(search: nil).isEmpty)

        try await library.uninstall(fresh.coordinate)
        #expect(harness.uninstalls == [fresh.coordinate])
        #expect(!library.isInstalled(fresh.coordinate))
    }

    @Test func cancellingStopsTheInstallAndStoresNothing() async throws {
        let harness = Harness()
        harness.holdsInstall = true
        let fresh = harness.discovered[0]
        let library = harness.library
        let install = Task { try await library.install(fresh) }
        try await eventually { harness.installGate != nil }
        library.cancelInstall(fresh.coordinate)
        #expect(harness.lastControl?.isCancelled() == true)
        harness.installGate?.resume()
        await #expect(throws: MarmotKitError.self) { try await install.value }
        #expect(library.installProgress.isEmpty)
        #expect(!library.isInstalled(fresh.coordinate))
    }

    @Test func switchingAccountsCancelsAnInstallInFlight() async throws {
        let harness = Harness()
        harness.holdsInstall = true
        let library = harness.library
        let install = Task { try await library.install(harness.discovered[0]) }
        try await eventually { harness.installGate != nil }
        harness.scope = EmojiSetScope(accountRef: "bob", runtimeGeneration: 1)
        await library.loadInstalledIfNeeded()
        #expect(harness.lastControl?.isCancelled() == true)
        #expect(library.installProgress.isEmpty)
        harness.installGate?.resume()
        await #expect(throws: (any Error).self) { try await install.value }
    }

    @Test func aFailedPreviewIsNotFetchedAgainUntilRetried() async {
        let harness = Harness()
        let images = harness.library.images
        let preview = EmojiSetImageStore.Source.preview(coordinate: "c", eventIdHex: "e", shortcode: "wave")
        harness.previewError = MarmotKitError.EmojiSetNetwork(details: "offline")
        #expect(await images.image(for: preview, pixelSize: 40, scale: 2) == nil)
        #expect(await images.image(for: preview, pixelSize: 40, scale: 2) == nil)
        #expect(harness.previewFetches == 1)
        #expect(images.hasFailed(preview, pixelSize: 40))

        harness.previewError = nil
        #expect(await images.retry(preview, pixelSize: 40, scale: 2) != nil)
        #expect(await images.image(for: preview, pixelSize: 40, scale: 2) != nil)
        #expect(harness.previewFetches == 2)
    }

    @Test func installedImagesReadLocallyAndNeverFetch() async {
        let harness = Harness()
        let images = harness.library.images
        let stored = EmojiSetImageStore.Source.installed(coordinate: "c", shortcode: "wave", sha256: hex("ee"))
        #expect(await images.image(for: stored, pixelSize: 40, scale: 2) != nil)
        #expect(harness.localReads == 1)
        #expect(harness.previewFetches == 0)

        harness.scope = EmojiSetScope(accountRef: "bob", runtimeGeneration: 1)
        #expect(images.cached(stored, pixelSize: 40) == nil)
    }
}

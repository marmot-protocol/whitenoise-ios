import Testing
import MarmotKit
@testable import whitenoise_ios

/// The key package screen's store. Loading itself goes through MDK; these
/// check the decisions around it that need no runtime: a failed load for
/// another account shows nothing of the previous one, a failed reload of the
/// same account keeps its cached data, and a publish or delete is ignored while
/// one that blocks it is in flight. The extension below drives the store
/// against `FakeKeyPackageRuntime` for the reload guards and the busy flags.
///
/// `AppState.test()` opens no runtime, so a load fails at
/// `currentMarmotClient()`, and a publish or delete that gets past its guard
/// shows a failure toast. The control tests prove that; the guard tests rely
/// on the absence of that toast.
@MainActor
struct KeyPackagesViewModelTests {
    /// A screen showing `account`'s packages, history and relays mid-reload.
    private func loadedModel(for account: String) -> KeyPackagesViewModel {
        let model = KeyPackagesViewModel()
        let current = keyPackage(eventId: "current", publishedAt: 2, local: true, relay: true)
        let other = keyPackage(eventId: "other", publishedAt: 1, local: false, relay: true)
        let inventory = [
            AccountKeyPackageInventoryEntryFfi(record: current, localState: .current),
            AccountKeyPackageInventoryEntryFfi(record: other, localState: .notLocal),
        ]
        model.inventory = inventory
        model.packages = [current, other]
        model.presentation = KeyPackagesPresentation(inventory: inventory)
        model.relayHistory = [keyPackageRelayEvent(eventId: "history")]
        model.lists = relayLists(bootstrapRelays: ["wss://account.example"], nip65: [], inbox: [])
        model.hasLoaded = true
        model.loadedRef = account
        model.isLoading = true
        model.relayHistoryError = "old history error"
        model.maintenanceLoadError = "old maintenance error"
        return model
    }

    private func expectNothingShown(_ model: KeyPackagesViewModel, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(model.packages.isEmpty, sourceLocation: sourceLocation)
        #expect(model.inventory.isEmpty, sourceLocation: sourceLocation)
        #expect(model.presentation.current == nil, sourceLocation: sourceLocation)
        #expect(model.presentation.otherRelayPackages.isEmpty, sourceLocation: sourceLocation)
        #expect(model.relayHistory.isEmpty, sourceLocation: sourceLocation)
        #expect(model.relayHistoryError == nil, sourceLocation: sourceLocation)
        #expect(model.lists == nil, sourceLocation: sourceLocation)
        #expect(model.maintenanceLoadError == nil, sourceLocation: sourceLocation)
        #expect(!model.hasLoaded, sourceLocation: sourceLocation)
        #expect(!model.isLoading, sourceLocation: sourceLocation)
    }

    @Test func signingOutClearsTheScreen() async {
        let model = loadedModel(for: "account")
        model.loadError = "old load error"
        #expect(model.presentation.current != nil)

        await model.reload(using: AppState.test())

        expectNothingShown(model)
        #expect(model.loadedRef == nil)
        #expect(model.loadError == nil)
    }

    /// A failed load for another account shows nothing of the previous one.
    @Test func switchingAccountsClearsThePreviousAccountsScreen() async {
        let model = loadedModel(for: "account")
        let appState = AppState.test()
        appState.activeAccountRef = "another-account"

        await model.reload(using: appState)

        expectNothingShown(model)
        #expect(model.loadError != nil)
    }

    /// A failed reload of the account already on screen keeps its cached data
    /// and reports the error.
    @Test func aFailedReloadOfTheSameAccountKeepsItsCachedData() async {
        let model = loadedModel(for: "account")
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState)

        #expect(model.packages.map(\.eventIdHex) == ["current", "other"])
        #expect(model.presentation.current?.publishedAt == 2)
        #expect(model.relayHistory.map(\.eventIdHex) == ["history"])
        #expect(model.lists?.bootstrapRelays == ["wss://account.example"])
        #expect(model.relayHistoryError == "old history error")
        #expect(model.maintenanceLoadError == "old maintenance error")
        #expect(model.loadedRef == "account")
        #expect(model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.loadError != nil)
    }

    @Test func anAllowedPublishReachesTheRuntime() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.publishNew(using: appState)

        #expect(appState.toastState.activeToast != nil)
        #expect(!model.isPublishing)
    }

    @Test func publishingIsIgnoredWhileAPublishIsInFlight() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.isPublishing = true

        await model.publishNew(using: appState)

        #expect(appState.toastState.activeToast == nil)
        #expect(model.isPublishing)
    }

    @Test func publishingIsIgnoredWhileADeleteIsInFlight() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.deletingEventIds = ["event"]

        await model.publishNew(using: appState)

        #expect(appState.toastState.activeToast == nil)
    }

    @Test func deletingIsIgnoredWhileAPublishIsInFlight() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.isPublishing = true

        await model.delete(keyPackage(eventId: "event", local: true, relay: true), using: appState)

        #expect(appState.toastState.activeToast == nil)
    }

    @Test func aSecondDeleteOfAPackageInFlightIsIgnored() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.deletingEventIds = ["event"]

        await model.delete(keyPackage(eventId: "event", local: true, relay: true), using: appState)

        // The first delete still owns the id; the second never reached the runtime.
        #expect(model.deletingEventIds == ["event"])
        #expect(appState.toastState.activeToast == nil)
    }

    /// Only the same package is blocked: deleting another one while a delete is
    /// in flight still reaches the runtime, and releases only its own id.
    @Test func deletingAnotherPackageWhileOneIsInFlightReachesTheRuntime() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.deletingEventIds = ["event"]

        await model.delete(keyPackage(eventId: "other", local: true, relay: true), using: appState)

        #expect(appState.toastState.activeToast != nil)
        #expect(model.deletingEventIds == ["event"])
    }
}

/// Reloads against a fake runtime: an older reload, or one whose account or task
/// changed while a step was pending, commits nothing more; only the newest
/// reload clears the spinner; and the publish and delete paths.
extension KeyPackagesViewModelTests {
    @Test(arguments: FakeKeyPackageRuntime.Step.allCases)
    func anOlderReloadOfTheSameAccountNeverOverwritesANewerOne(_ step: FakeKeyPackageRuntime.Step) async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(step)

        let older = Task { await model.reload(using: appState, refresh: true) }
        try await hold.entered.wait()
        runtime.version = 2
        await model.reload(using: appState, refresh: true)
        hold.release.signal()
        await older.value

        expectShowing(model, runtime.packageId(for: "account", version: 2, refreshed: true))
        // The older reload stopped at its next check: each later step ran once, for the newer reload.
        for later in FakeKeyPackageRuntime.Step.allCases.drop(while: { $0 != step }).dropFirst() {
            #expect(runtime.calls[later] == 1)
        }
        #expect(model.lists == runtime.lists(for: "account", version: 2))
        #expect(model.relayHistory.map(\.eventIdHex) == [runtime.historyId(for: "account", version: 2)])
        #expect(!model.isLoading)
    }

    /// The account changed while a step was pending and no reload for the new
    /// one has started yet: the old account's load commits nothing more.
    @Test(arguments: FakeKeyPackageRuntime.Step.allCases.filter { $0 != .local })
    func aReloadWhoseAccountChangedCommitsNothingMore(_ step: FakeKeyPackageRuntime.Step) async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(step)

        let reload = Task { await model.reload(using: appState, refresh: true) }
        try await hold.entered.wait()
        appState.activeAccountRef = "another-account"
        hold.release.signal()
        await reload.value

        expectNoLaterSteps(after: step, in: runtime)
        // Only the first step's packages were committed, while the account was current.
        #expect(model.lists == nil)
        #expect(model.relayHistory.isEmpty)
        expectShowing(model, runtime.packageId(for: "account", version: 1))
    }

    @Test func aReloadWhoseAccountChangedDuringTheLocalReadCommitsNothing() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(.local)

        let reload = Task { await model.reload(using: appState) }
        try await hold.entered.wait()
        appState.activeAccountRef = "another-account"
        hold.release.signal()
        await reload.value

        #expect(model.packages.isEmpty)
        #expect(!model.hasLoaded)
        #expect(model.loadedRef == nil)
    }

    @Test(arguments: FakeKeyPackageRuntime.Step.allCases)
    func aCancelledReloadCommitsNothingMore(_ step: FakeKeyPackageRuntime.Step) async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(step)

        let reload = Task { await model.reload(using: appState, refresh: true) }
        try await hold.entered.wait()
        reload.cancel()
        hold.release.signal()
        await reload.value

        expectNoLaterSteps(after: step, in: runtime)
        #expect(model.lists == nil)
        #expect(model.relayHistory.isEmpty)
        if step == .local {
            #expect(model.packages.isEmpty)
        }
    }

    /// A reload whose account changed while it was pending reports none of its
    /// errors under the new account.
    @Test func aFailureOfAReloadWhoseAccountChangedIsNotReported() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.lists]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(.lists)

        let reload = Task { await model.reload(using: appState) }
        try await hold.entered.wait()
        appState.activeAccountRef = "another-account"
        hold.release.signal()
        await reload.value

        #expect(model.loadError == nil)
    }

    /// The screen shows exactly `id`: its packages, the ownership inventory and
    /// the current-package card.
    private func expectShowing(
        _ model: KeyPackagesViewModel, _ id: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(model.packages.map(\.eventIdHex) == [id], sourceLocation: sourceLocation)
        #expect(model.inventory.map(\.record.eventIdHex) == [id], sourceLocation: sourceLocation)
        #expect(model.presentation.current?.identifier == id, sourceLocation: sourceLocation)
    }

    private func expectNoLaterSteps(
        after step: FakeKeyPackageRuntime.Step, in runtime: FakeKeyPackageRuntime,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for later in FakeKeyPackageRuntime.Step.allCases.drop(while: { $0 != step }).dropFirst() {
            #expect(runtime.calls[later, default: 0] == 0, sourceLocation: sourceLocation)
        }
    }

    /// An older reload of the same account that fails after a newer one
    /// finished doesn't put its error over the newer result.
    @Test func aFailureOfAnOlderReloadIsNotReported() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failingListsVersion = 1
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(.lists)

        let older = Task { await model.reload(using: appState) }
        try await hold.entered.wait()
        runtime.version = 2
        await model.reload(using: appState)
        hold.release.signal()
        await older.value

        #expect(model.loadError == nil)
        expectShowing(model, runtime.packageId(for: "account", version: 2))
    }

    /// With no current package on this device, the card shows the one the
    /// maintenance status names.
    @Test func theMaintenanceStatusNamesTheCurrentPackageWhenThisDeviceHasNone() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.localState = .notLocal
        runtime.statusNamesLocalPackage = true
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState)

        #expect(model.presentation.current?.identifier == runtime.packageId(for: "account", version: 1))
    }

    @Test func aRefreshFailureKeepsTheLocalPackagesAndReportsIt() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.refresh]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState, refresh: true)

        #expect(model.loadError != nil)
        expectShowing(model, runtime.packageId(for: "account", version: 1))
        #expect(model.lists == nil)
    }

    /// A superseded reload that finishes first leaves the newer reload's
    /// spinner on; the newer one clears it.
    @Test func onlyTheNewestReloadClearsTheSpinner() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let olderHold = runtime.hold(.local)

        let older = Task { await model.reload(using: appState) }
        try await olderHold.entered.wait()
        let newerHold = runtime.hold(.lists)
        let newer = Task { await model.reload(using: appState) }
        try await newerHold.entered.wait()
        olderHold.release.signal()
        await older.value

        #expect(model.isLoading)
        newerHold.release.signal()
        await newer.value
        #expect(!model.isLoading)
    }

    @Test func aRefreshUsesTheLoadedBootstrapRelaysAndShowsTheRefreshedPackages() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState, refresh: true)

        let relays = runtime.lists(for: "account", version: 1).bootstrapRelays
        #expect(runtime.refreshRelays == [relays])
        #expect(runtime.historyRelays == [relays])
        expectShowing(model, runtime.packageId(for: "account", version: 1, refreshed: true))
        #expect(model.hasLoaded)
        #expect(model.loadedRef == "account")
    }

    @Test func aPlainReloadShowsTheLocalPackagesWithoutRefreshing() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState)

        #expect(runtime.refreshRelays.isEmpty)
        expectShowing(model, runtime.packageId(for: "account", version: 1))
    }

    /// The maintenance status and relay history are optional: their failures
    /// show their own error, and the rest of the screen still loads.
    @Test func maintenanceAndHistoryFailuresStillShowTheRestOfTheScreen() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.maintenance, .history]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState)

        #expect(model.maintenanceLoadError != nil)
        #expect(model.relayHistoryError != nil)
        #expect(model.relayHistory.isEmpty)
        #expect(model.lists == runtime.lists(for: "account", version: 1))
        expectShowing(model, runtime.packageId(for: "account", version: 1))
        #expect(model.loadError == nil)
    }

    /// A relay-list failure after the local packages are shown keeps them and
    /// reports the error.
    @Test func aRelayListFailureKeepsTheLocalPackagesAndReportsIt() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.lists]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.reload(using: appState)

        #expect(model.loadError != nil)
        expectShowing(model, runtime.packageId(for: "account", version: 1))
        #expect(model.lists == nil)
        #expect(!model.isLoading)
    }

    @Test func publishingIsBusyWhileItRunsThenRefreshes() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        let hold = runtime.hold(.publish)

        let publish = Task { await model.publishNew(using: appState) }
        try await hold.entered.wait()
        #expect(model.isPublishing)
        hold.release.signal()
        await publish.value

        #expect(!model.isPublishing)
        #expect(appState.activeToast?.style == .success)
        #expect(runtime.refreshRelays.count == 1)
    }

    @Test func aFailedPublishShowsAnErrorAndDoesNotReload() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.publish]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.publishNew(using: appState)

        #expect(appState.activeToast?.style == .error)
        #expect(runtime.calls[.local, default: 0] == 0)
        #expect(!model.isPublishing)
    }

    @Test func deletingMarksThePackageBusyUsesTheBootstrapRelaysThenRefreshes() async throws {
        let runtime = FakeKeyPackageRuntime()
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        await model.reload(using: appState)
        let package = try #require(model.packages.first)
        let hold = runtime.hold(.delete)

        let delete = Task { await model.delete(package, using: appState) }
        try await hold.entered.wait()
        #expect(model.deletingEventIds == [package.eventIdHex])
        hold.release.signal()
        await delete.value

        #expect(model.deletingEventIds.isEmpty)
        #expect(runtime.deletes.map(\.eventId) == [package.eventIdHex])
        #expect(runtime.deletes.map(\.relays) == [runtime.lists(for: "account", version: 1).bootstrapRelays])
        #expect(appState.activeToast?.style == .success)
        #expect(runtime.refreshRelays.count == 1)
    }

    @Test func aFailedDeleteShowsAnErrorAndReleasesThePackage() async throws {
        let runtime = FakeKeyPackageRuntime()
        runtime.failing = [.delete]
        let model = KeyPackagesViewModel(runtime: { _ in runtime })
        let appState = AppState.test()
        appState.activeAccountRef = "account"

        await model.delete(keyPackage(eventId: "event", local: true, relay: true), using: appState)

        #expect(appState.activeToast?.style == .error)
        #expect(model.deletingEventIds.isEmpty)
        #expect(runtime.calls[.local, default: 0] == 0)
    }
}

/// Answers each read with data tagged by account and `version`, so a test can
/// tell which reload's result is on screen, and can park any step until the
/// test releases it.
@MainActor
final class FakeKeyPackageRuntime: KeyPackageRuntime {
    nonisolated enum Step: CaseIterable, Sendable { case local, lists, refresh, maintenance, history }
    enum Action { case publish, delete }
    enum Failure: Hashable { case lists, refresh, maintenance, history, publish, delete }
    struct Hold { let entered = TestLatch(); let release = TestLatch() }
    struct Failed: Error {}

    /// Read when each step is called, so a held step keeps the version it began with.
    var version = 1
    var failing: Set<Failure> = []
    /// The relay-list read fails only for a reload that began at this version.
    var failingListsVersion: Int?
    var localState: AccountKeyPackageLocalStateFfi = .current
    /// The maintenance status names the local package as current.
    var statusNamesLocalPackage = false
    private var holds: [String: Hold] = [:]
    private(set) var calls: [Step: Int] = [:]
    private(set) var refreshRelays: [[String]] = []
    private(set) var historyRelays: [[String]] = []
    private(set) var deletes: [(eventId: String, relays: [String])] = []

    func hold(_ step: Step) -> Hold { hold(key: "\(step)") }
    func hold(_ action: Action) -> Hold { hold(key: "\(action)") }

    private func hold(key: String) -> Hold {
        let hold = Hold()
        holds[key] = hold
        return hold
    }

    private func pass(_ key: String) async throws {
        guard let hold = holds.removeValue(forKey: key) else { return }
        hold.entered.signal()
        // A missed release fails the test here; the store would otherwise
        // swallow the timeout as an ordinary runtime error.
        await hold.release.hold()
    }

    func packageId(for account: String, version: Int, refreshed: Bool = false) -> String {
        "\(account)-v\(version)\(refreshed ? "-refreshed" : "")"
    }

    func historyId(for account: String, version: Int) -> String { "\(account)-history-v\(version)" }

    func lists(for account: String, version: Int) -> AccountRelayListsFfi {
        relayLists(bootstrapRelays: ["wss://\(account)-v\(version).example"], nip65: [], inbox: [])
    }

    private func inventory(_ id: String) -> [AccountKeyPackageInventoryEntryFfi] {
        [AccountKeyPackageInventoryEntryFfi(record: keyPackage(eventId: id, local: true, relay: true),
                                            localState: localState)]
    }

    func localKeyPackages(accountRef: String) async throws -> [AccountKeyPackageInventoryEntryFfi] {
        calls[.local, default: 0] += 1
        let version = version
        try await pass("\(Step.local)")
        return inventory(packageId(for: accountRef, version: version))
    }

    func keyPackageRelayLists(accountRef: String) async throws -> AccountRelayListsFfi {
        calls[.lists, default: 0] += 1
        let version = version
        try await pass("\(Step.lists)")
        if failing.contains(.lists) || failingListsVersion == version { throw Failed() }
        return lists(for: accountRef, version: version)
    }

    func refreshKeyPackages(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageInventoryEntryFfi] {
        refreshRelays.append(bootstrapRelays)
        calls[.refresh, default: 0] += 1
        let version = version
        try await pass("\(Step.refresh)")
        if failing.contains(.refresh) { throw Failed() }
        return inventory(packageId(for: accountRef, version: version, refreshed: true))
    }

    func keyPackageMaintenanceStatus(accountRef: String) async throws -> KeyPackageMaintenanceStatusFfi? {
        calls[.maintenance, default: 0] += 1
        let version = version
        try await pass("\(Step.maintenance)")
        if failing.contains(.maintenance) { throw Failed() }
        guard statusNamesLocalPackage else { return nil }
        let id = packageId(for: accountRef, version: version)
        return KeyPackageMaintenanceStatusFfi(
            stableSlotId: "slot", phase: .quiet, currentKeyPackageRefHex: "keyPackageRef-\(id)", currentNotBefore: nil,
            currentNotAfter: nil, authoredEventIdHex: id, authoredEventCreatedAt: 1, acceptedFanoutTargets: 0,
            unattemptedFanoutTargets: 0, failedFanoutTargets: 0, policyProhibitedFanoutTargets: 0, refreshAt: nil,
            lastConsumedKeyPackageRefHex: nil, retainedPrivateMaterialCount: 0, pendingEventIdHex: nil,
            pendingAttemptCount: 0, pendingLastFailureCode: nil)
    }

    func keyPackageRelayEvents(accountRef: String, bootstrapRelays: [String]) async throws
        -> [AccountKeyPackageRelayEventFfi] {
        historyRelays.append(bootstrapRelays)
        calls[.history, default: 0] += 1
        let version = version
        try await pass("\(Step.history)")
        if failing.contains(.history) { throw Failed() }
        return [keyPackageRelayEvent(eventId: historyId(for: accountRef, version: version), account: accountRef)]
    }

    func publishNewKeyPackage(accountRef: String) async throws -> UInt64 {
        try await pass("\(Action.publish)")
        if failing.contains(.publish) { throw Failed() }
        return 1
    }

    func deleteAccountKeyPackage(accountRef: String, eventIdHex: String, relays: [String]) async throws -> UInt64 {
        try await pass("\(Action.delete)")
        if failing.contains(.delete) { throw Failed() }
        deletes.append((eventIdHex, relays))
        return 1
    }
}

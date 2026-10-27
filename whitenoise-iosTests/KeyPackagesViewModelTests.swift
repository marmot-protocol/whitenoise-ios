import Testing
import MarmotKit
@testable import whitenoise_ios

/// The key package screen's store. Loading itself goes through MDK; these
/// check the decisions around it that need no runtime: the screen is cleared
/// before another account loads and kept for a failed reload of the same one,
/// and publish and delete never overlap. The guards that stop a slower,
/// older reload from committing its result are not covered yet (#1228).
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
        model.relayHistory = [AccountKeyPackageRelayEventFfi(
            accountIdHex: "account", keyPackageId: "history", keyPackageRefHex: "history-ref",
            eventIdHex: "history", createdAt: 1, keyPackageBytes: 32, sourceRelays: ["wss://relay.example"],
            isCurrent: false)]
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

    /// Switching accounts clears the previous account's screen before loading,
    /// so even a failed load never shows it under the new account.
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

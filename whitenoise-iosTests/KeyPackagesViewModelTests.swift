import Testing
import MarmotKit
@testable import whitenoise_ios

/// The key package screen's store. Loading itself goes through MDK; these
/// check the decisions around it that need no runtime: one account's packages
/// never show under another, and publish and delete never overlap.
@MainActor
struct KeyPackagesViewModelTests {
    private func loadedModel() -> KeyPackagesViewModel {
        let model = KeyPackagesViewModel()
        let package = keyPackage(eventId: "previous", local: true, relay: true)
        model.inventory = [AccountKeyPackageInventoryEntryFfi(record: package, localState: .current)]
        model.packages = [package]
        model.hasLoaded = true
        model.loadError = "old error"
        model.maintenanceLoadError = "old maintenance error"
        model.relayHistoryError = "old history error"
        return model
    }

    @Test func signingOutClearsTheScreen() async {
        let model = loadedModel()

        await model.reload(using: AppState.test())

        #expect(model.packages.isEmpty)
        #expect(model.inventory.isEmpty)
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.loadError == nil)
        #expect(model.maintenanceLoadError == nil)
        #expect(model.relayHistoryError == nil)
    }

    /// Switching accounts clears the previous account's packages before the
    /// new load, so even a failed load never shows them under the new account.
    @Test func anotherAccountsLoadNeverShowsThePreviousPackages() async {
        let model = loadedModel()
        let appState = AppState.test()
        appState.activeAccountRef = "another-account"

        // No runtime is open, so this load fails after the reset.
        await model.reload(using: appState)

        #expect(model.packages.isEmpty)
        #expect(model.inventory.isEmpty)
        #expect(!model.hasLoaded)
        #expect(!model.isLoading)
        #expect(model.loadError != nil)
    }

    @Test func publishingWaitsForAnInFlightDelete() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.deletingEventIds = ["event"]

        await model.publishNew(using: appState)

        #expect(!model.isPublishing)
        #expect(appState.toastState.activeToast == nil)
    }

    @Test func deletingWaitsForAnInFlightPublish() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.isPublishing = true

        await model.delete(keyPackage(eventId: "event", local: true, relay: true), using: appState)

        #expect(model.deletingEventIds.isEmpty)
        #expect(appState.toastState.activeToast == nil)
    }

    /// A second delete of a package whose first delete is still in flight is
    /// ignored before it reaches the runtime.
    @Test func aSecondDeleteOfTheSamePackageIsIgnored() async {
        let model = KeyPackagesViewModel()
        let appState = AppState.test()
        appState.activeAccountRef = "account"
        model.deletingEventIds = ["event"]

        await model.delete(keyPackage(eventId: "event", local: true, relay: true), using: appState)

        #expect(model.deletingEventIds == ["event"])
        #expect(appState.toastState.activeToast == nil)
    }
}

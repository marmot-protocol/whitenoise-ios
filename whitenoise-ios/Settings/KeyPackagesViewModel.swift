import Foundation
import MarmotKit

/// Screen store for `KeyPackagesView`: owns the key-package list + UI state and
/// the load/publish/delete actions, so the view is pure rendering. The pure
/// presentation helpers (byte/date formatting,
/// relay sanitizing) stay on the view. Methods take `AppState` rather than
/// retaining it.
@MainActor
@Observable
final class KeyPackagesViewModel {
    var packages: [AccountKeyPackageFfi] = []
    var lists: AccountRelayListsFfi?
    var presentation = KeyPackagesPresentation()
    var hasLoaded = false
    private var loadedRef: String?
    // Overlapping reloads (pull-to-refresh racing the task restart) must not
    // let an older result overwrite a newer one, even for the same account.
    private var reloadTicket = 0
    var isLoading = false
    var isPublishing = false
    var deletingEventIds: Set<String> = []
    var loadError: String?
    var maintenanceLoadError: String?

    var bootstrapRelays: [String] {
        lists.map(RelaySettings.bootstrapRelays(from:)) ?? MarmotClient.seedRelays
    }

    func reload(using appState: AppState) async {
        guard let ref = appState.activeAccountRef else {
            reloadTicket += 1
            isLoading = false
            loadedRef = nil
            loadError = nil
            packages = []
            lists = nil
            presentation = KeyPackagesPresentation()
            hasLoaded = false
            maintenanceLoadError = nil
            return
        }
        isLoading = true
        loadError = nil
        reloadTicket += 1
        let ticket = reloadTicket
        // A superseded reload must not clear the newer reload's spinner —
        // that flashes "no key packages" while the real load is in flight.
        defer {
            if reloadTicket == ticket {
                isLoading = false
            }
        }
        // The model persists across account changes; never show one
        // account's data while another's loads.
        if loadedRef != ref {
            packages = []
            lists = nil
            presentation = KeyPackagesPresentation()
            hasLoaded = false
            maintenanceLoadError = nil
        }

        do {
            let client = try appState.currentMarmotClient()
            let loadedLists = try await client.accountRelayLists(accountRef: ref)
            // The screen's task restarts on account change, but the cancelled
            // body still runs to completion — a straggling load must not
            // render the previous account's key packages and bootstrap relays
            // under the new one. Both values commit together after the final
            // guard so a failed or cancelled package load can't leave
            // mixed-account state.
            guard !Task.isCancelled, reloadTicket == ticket, appState.activeAccountRef == ref else { return }
            let loadedPackages = try await client.accountKeyPackages(
                accountRef: ref,
                bootstrapRelays: RelaySettings.bootstrapRelays(from: loadedLists)
            )
            guard !Task.isCancelled, reloadTicket == ticket, appState.activeAccountRef == ref else { return }
            let loadedMaintenanceStatus: KeyPackageMaintenanceStatusFfi?
            let loadedMaintenanceError: String?
            do {
                loadedMaintenanceStatus = try await client.keyPackageMaintenanceStatus(
                    accountRef: ref
                )
                loadedMaintenanceError = nil
            } catch {
                loadedMaintenanceStatus = nil
                loadedMaintenanceError = error.localizedDescription
            }
            guard !Task.isCancelled, reloadTicket == ticket, appState.activeAccountRef == ref else { return }
            lists = loadedLists
            packages = loadedPackages
            presentation = KeyPackagesPresentation(packages: loadedPackages, status: loadedMaintenanceStatus)
            hasLoaded = true
            maintenanceLoadError = loadedMaintenanceError
            loadedRef = ref
        } catch {
            guard reloadTicket == ticket, appState.activeAccountRef == ref else { return }
            loadError = error.localizedDescription
        }
    }

    func publishNew(using appState: AppState) async {
        guard !isPublishing, deletingEventIds.isEmpty, let ref = appState.activeAccountRef else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.publishNewKeyPackage(accountRef: ref)
            Haptics.success()
            appState.present(.success(L10n.string("New key package published")))
            await reload(using: appState)
        } catch {
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Publish failed"), error: error))
        }
    }

    func delete(_ pkg: AccountKeyPackageFfi, using appState: AppState) async {
        guard !isPublishing, let ref = appState.activeAccountRef else { return }
        let eventId = pkg.eventIdHex
        guard !deletingEventIds.contains(eventId) else { return }
        deletingEventIds.insert(eventId)
        defer { deletingEventIds.remove(eventId) }

        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.deleteAccountKeyPackage(
                accountRef: ref,
                eventIdHex: eventId,
                relays: bootstrapRelays
            )
            Haptics.success()
            appState.present(.success(L10n.string("Key package deleted")))
            await reload(using: appState)
        } catch {
            Haptics.error()
            appState.present(UserFacingError.toast(title: L10n.string("Delete failed"), error: error))
        }
    }
}

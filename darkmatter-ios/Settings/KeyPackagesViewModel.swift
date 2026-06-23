import Foundation
import MarmotKit

/// Screen store for `KeyPackagesView`: owns the key-package list + UI state and
/// the load/publish/delete actions, so the view is pure rendering. The pure
/// presentation helpers (section grouping, badge titles, byte/date formatting,
/// relay sanitizing) stay on the view. Methods take `AppState` rather than
/// retaining it.
@MainActor
@Observable
final class KeyPackagesViewModel {
    var packages: [AccountKeyPackageFfi] = []
    var lists: AccountRelayListsFfi?
    var isLoading = false
    var isPublishing = false
    var deletingEventIds: Set<String> = []
    var loadError: String?

    var bootstrapRelays: [String] {
        lists.map(RelaySettings.bootstrapRelays(from:)) ?? MarmotClient.seedRelays
    }

    func reload(using appState: AppState) async {
        guard let ref = appState.activeAccountRef else {
            packages = []
            lists = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let loadedLists = try await appState.currentMarmotClient().accountRelayLists(accountRef: ref)
            lists = loadedLists
            packages = try await appState.marmot.accountKeyPackages(
                accountRef: ref,
                bootstrapRelays: RelaySettings.bootstrapRelays(from: loadedLists)
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    func publishNew(using appState: AppState) async {
        guard !isPublishing, let ref = appState.activeAccountRef else { return }
        isPublishing = true
        defer { isPublishing = false }

        do {
            _ = try await appState.marmot.publishNewKeyPackage(accountRef: ref)
            Haptics.success()
            appState.present(.success(L10n.string("New key package published")))
            await reload(using: appState)
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Publish failed"), message: error.localizedDescription))
        }
    }

    func delete(_ pkg: AccountKeyPackageFfi, using appState: AppState) async {
        guard let ref = appState.activeAccountRef else { return }
        let eventId = pkg.eventIdHex
        guard !deletingEventIds.contains(eventId) else { return }
        deletingEventIds.insert(eventId)
        defer { deletingEventIds.remove(eventId) }

        do {
            _ = try await appState.marmot.deleteAccountKeyPackage(
                accountRef: ref,
                eventIdHex: eventId,
                relays: bootstrapRelays
            )
            Haptics.success()
            appState.present(.success(L10n.string("Key package deleted")))
            await reload(using: appState)
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Delete failed"), message: error.localizedDescription))
        }
    }
}

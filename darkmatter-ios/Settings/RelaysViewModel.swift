import SwiftUI
import MarmotKit

/// Screen store for `RelaysView`. Holds the relay-editing UI state and routes
/// reads/edits through Marmot (off the MainActor via `MarmotClient`), so the
/// view is pure rendering. The relay projection + validation live in the pure
/// `RelaySettings` helpers; this just orchestrates load/save and UI state.
///
/// Methods take `AppState` rather than retaining it — the view always has it via
/// `@Environment`, and this keeps the store free of a back-reference.
@MainActor
@Observable
final class RelaysViewModel {
    var lists: AccountRelayListsFfi?
    var pendingUrl = ""
    var isSaving = false
    var saveError: String?
    var savedAt: Date?

    var currentRelays: [String] {
        guard let lists else { return [] }
        return RelaySettings.editableRelays(from: lists)
    }

    var canAdd: Bool {
        guard lists != nil,
              !isSaving,
              let normalized = RelaySettings.normalizedRelayURL(pendingUrl)
        else { return false }
        return !currentRelays.contains(normalized)
    }

    func reload(using appState: AppState) async {
        guard let ref = appState.activeAccountRef else {
            lists = nil
            return
        }
        do {
            lists = try await appState.currentMarmotClient().accountRelayLists(accountRef: ref)
        } catch {
            lists = nil
        }
    }

    func addPending(using appState: AppState) {
        guard let normalized = RelaySettings.normalizedRelayURL(pendingUrl), canAdd else { return }
        Task {
            if await save(currentRelays + [normalized], using: appState) {
                pendingUrl = ""
            }
        }
    }

    func deleteRelays(at indexSet: IndexSet, using appState: AppState) {
        var next = currentRelays
        next.remove(atOffsets: indexSet)
        Task { await save(next, using: appState) }
    }

    @discardableResult
    func save(_ relays: [String], using appState: AppState) async -> Bool {
        guard let accountRef = appState.activeAccountRef else { return false }
        let normalized = RelaySettings.normalizedRelayURLs(relays)
        guard !normalized.isEmpty else {
            saveError = L10n.string("Keep at least one relay.")
            Haptics.error()
            return false
        }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            lists = try await RelaySettings.saveAccountRelays(
                accountRef: accountRef,
                relays: normalized,
                currentLists: lists,
                manager: appState.marmot
            )
            savedAt = Date()
            Haptics.success()
            appState.present(.success(L10n.string("Relay lists updated")))
            return true
        } catch {
            if let failure = error as? RelaySettingsSaveFailure,
               let reloadedLists = failure.reloadedLists {
                lists = reloadedLists
            }
            Haptics.error()
            saveError = error.localizedDescription
            appState.present(.error(L10n.string("Relay update failed"), message: error.localizedDescription))
            return false
        }
    }
}

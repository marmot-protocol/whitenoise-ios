import Foundation
import MarmotKit

/// Screen store for `AddMembersSheet`: owns the staged recipients + the
/// add/invite flow, preserving the off-main normalization and #260/#274
/// concurrency guards verbatim, so the view is pure rendering. The sheet is
/// callback-based (the parent supplies `normalize` + `onSubmit`); those, plus
/// `AppState` and the view's `dismiss`, are passed into the model's methods
/// rather than retained.
@MainActor
@Observable
final class AddMembersSheetViewModel {
    var members: [MemberRefFfi] = []
    var pending = ""
    var isInviting = false
    var error: String?
    var showScanner = false

    @discardableResult
    func add(
        _ raw: String,
        normalize: (String) async throws -> MemberRefFfi,
        using appState: AppState
    ) async -> Bool {
        // Normalize off the MainActor; only hop back to mutate members/error (#260).
        let normalizedResult = await AddMembersPresentation.normalizedMember(raw, normalize: normalize)
        switch normalizedResult {
        case .empty:
            return true
        case .invalid:
            Haptics.error()
            error = L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
            return false
        case .normalized(let normalized):
            // Stage against the live members list (post-await) so concurrent
            // adds dedup correctly instead of racing on a stale snapshot.
            switch AddMembersPresentation.stage(normalized, existingMembers: members) {
            case .empty, .invalid:
                return false
            case .duplicate:
                clearPendingIfUnchanged(raw)
                error = nil
                Haptics.selection()
                return true
            case .added(let updatedMembers, let addedMember):
                members = updatedMembers
                clearPendingIfUnchanged(raw)
                error = nil
                Haptics.success()
                _ = appState.profile(forAccountIdHex: addedMember.accountIdHex)
                return true
            }
        }
    }

    /// Clear the pending field only if it still holds the value we normalized,
    /// so an older add completing off-main can't erase text the user typed
    /// while the FFI was in flight (#260/#274).
    func clearPendingIfUnchanged(_ raw: String) {
        if pending == raw {
            pending = ""
        }
    }

    @discardableResult
    func addPending(normalize: (String) async throws -> MemberRefFfi, using appState: AppState) async -> Bool {
        await add(pending, normalize: normalize, using: appState)
    }

    func addScanned(_ raw: String, normalize: @escaping (String) async throws -> MemberRefFfi, using appState: AppState) {
        Task { await add(raw, normalize: normalize, using: appState) }
    }

    func invite(
        normalize: (String) async throws -> MemberRefFfi,
        onSubmit: ([String]) async throws -> Void,
        using appState: AppState,
        dismiss: () -> Void
    ) async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent invite tasks while the
        // off-main recipient normalization is still in flight (#260/#274).
        guard !isInviting else { return }
        isInviting = true
        // Validate the still-in-field text before clearing any prior validation
        // error (`addPending` sets its own error on invalid input). The in-flight
        // guard stays ahead of the await so a double-tap can't start two invites.
        guard await addPending(normalize: normalize, using: appState) else {
            isInviting = false
            return
        }
        guard !members.isEmpty else {
            isInviting = false
            return
        }
        error = nil
        do {
            try await onSubmit(members.map(\.memberRef))
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            self.error = error.localizedDescription
        }
    }
}

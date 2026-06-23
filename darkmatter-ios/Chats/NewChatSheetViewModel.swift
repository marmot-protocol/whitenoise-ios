import Foundation
import MarmotKit

/// Screen store for `NewChatSheet`: owns the staged recipients + group fields
/// and the add/normalize/create flow (preserving the off-main normalization and
/// #260/#274 concurrency guards verbatim), so the view is pure rendering. The
/// tested normalization statics stay on `NewChatSheet`; this calls them. `AppState`
/// and the view's `dismiss` are passed in rather than retained.
@MainActor
@Observable
final class NewChatSheetViewModel {
    var members: [MemberRefFfi] = []
    var pendingMember = ""
    var groupName = ""
    var groupDescription = ""
    var isCreating = false
    var error: String?
    var showScanner = false

    @discardableResult
    func addPending(using appState: AppState) async -> Bool {
        await add(
            pendingMember,
            invalidMessage: L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key."),
            using: appState
        )
    }

    @discardableResult
    func add(_ raw: String, invalidMessage: String, using appState: AppState) async -> Bool {
        // Normalize off the MainActor; only hop back to mutate members/error (#260).
        let normalizedResult = await NewChatSheet.normalizedMember(
            raw,
            normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) }
        )
        switch normalizedResult {
        case .empty:
            return true
        case .invalid:
            Haptics.error()
            error = invalidMessage
            return false
        case .normalized(let normalized):
            // Stage against the live members list (post-await) so concurrent
            // adds dedup correctly instead of racing on a stale snapshot.
            switch NewChatSheet.stage(normalized, existingMembers: members) {
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
        if pendingMember == raw {
            pendingMember = ""
        }
    }

    /// Add a recipient from a scanned profile QR code.
    func handleScan(_ raw: String, using appState: AppState) {
        Task { await add(raw, invalidMessage: L10n.string("That QR code isn't a Dark Matter profile."), using: appState) }
    }

    func create(using appState: AppState, dismiss: () -> Void) async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent create tasks while the
        // off-main recipient normalization is still in flight (#260/#274).
        guard !isCreating else { return }
        guard let accountRef = appState.activeAccountRef else { return }
        isCreating = true
        // Validate the still-in-field text before clearing any prior validation
        // error (`addPending` sets its own error on invalid input). The in-flight
        // guard stays ahead of the await so a double-tap can't start two creates.
        guard await addPending(using: appState) else {
            isCreating = false
            return
        }
        error = nil
        do {
            let groupIdHex = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: NewChatSheet.normalizedGroupName(groupName),
                memberRefs: members.map(\.memberRef),
                description: NewChatSheet.normalizedGroupDescription(groupDescription)
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the sheet open and name who can't be added.
                error = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be added yet.",
                    IdentityFormatter.short(account)
                )
            } else {
                error = marmotError.localizedDescription
                appState.present(.error(L10n.string("Couldn't create chat"), message: marmotError.localizedDescription))
            }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't create chat"), message: error.localizedDescription))
        }
        isCreating = false
    }
}

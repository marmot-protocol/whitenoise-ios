import Foundation
import MarmotKit

/// Screen store for `NewChatSheet`: owns group fields and delegates recipient
/// staging to the shared model used by add-members.
@MainActor
@Observable
final class NewChatSheetViewModel {
    let recipients = RecipientStagingModel()
    var groupName = ""
    var groupDescription = ""
    var isCreating = false

    @discardableResult
    func addPending(using appState: AppState) async -> Bool {
        await recipients.addPending(normalize: normalize(using: appState), warmProfile: warmProfile(using: appState))
    }

    /// Silent auto-stage on input change: stages a complete pasted/typed
    /// reference without requiring the "+" tap, and without erroring on partial
    /// input.
    func autoStagePending(using appState: AppState) async {
        await recipients.autoStagePendingIfComplete(
            normalize: normalize(using: appState),
            warmProfile: warmProfile(using: appState)
        )
    }

    @discardableResult
    func add(_ raw: String, invalidMessage: String, using appState: AppState) async -> Bool {
        await recipients.add(
            raw,
            invalidMessage: invalidMessage,
            normalize: normalize(using: appState),
            warmProfile: warmProfile(using: appState)
        )
    }

    /// Add a recipient from a scanned profile QR code.
    func handleScan(_ raw: String, using appState: AppState) {
        Task {
            await add(
                raw,
                invalidMessage: L10n.string("That QR code isn't a White Noise profile."),
                using: appState
            )
        }
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
        recipients.error = nil
        do {
            let client = try appState.currentMarmotClient()
            let groupIdHex = try await client.createGroup(
                accountRef: accountRef,
                name: NewChatSheet.normalizedGroupName(groupName),
                memberRefs: recipients.members.map(\.memberRef),
                description: NewChatSheet.normalizedGroupDescription(groupDescription)
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the sheet open and name who can't be added.
                recipients.error = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be added yet.",
                    IdentityFormatter.short(account)
                )
            } else {
                recipients.error = marmotError.localizedDescription
                appState.present(.error(L10n.string("Couldn't create chat"), message: marmotError.localizedDescription))
            }
        } catch {
            Haptics.error()
            recipients.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't create chat"), message: error.localizedDescription))
        }
        isCreating = false
    }

    private func normalize(using appState: AppState) -> RecipientStagingModel.Normalize {
        { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) }
    }

    private func warmProfile(using appState: AppState) -> RecipientStagingModel.ProfileWarmup {
        { _ = appState.profile(forAccountIdHex: $0) }
    }
}

import Foundation
import MarmotKit

/// Screen store for `NewChatSheet`: owns group fields and delegates member
/// collection to the shared picker used by add-members.
@MainActor
@Observable
final class NewChatSheetViewModel {
    let memberPicker = MemberPickerViewModel()
    var groupName = ""
    var groupDescription = ""
    var isCreating = false

    func create(using appState: AppState, dismiss: () -> Void) async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent create tasks while the
        // off-main member normalization is still in flight (#260/#274).
        guard !isCreating else { return }
        guard let accountRef = appState.activeAccountRef else { return }
        isCreating = true
        // Fold the still-in-field text before clearing any prior validation error
        // (`addPending` sets its own error on invalid input). The in-flight guard
        // stays ahead of the await so a double-tap can't start two creates.
        guard await memberPicker.addPending(
            normalize: normalize(using: appState),
            warmProfile: warmProfile(using: appState)
        ) else {
            isCreating = false
            return
        }
        guard !memberPicker.members.isEmpty else {
            isCreating = false
            return
        }
        memberPicker.error = nil
        do {
            let client = try appState.currentMarmotClient()
            let groupIdHex = try await client.createGroup(
                accountRef: accountRef,
                name: NewChatSheet.normalizedGroupName(groupName),
                memberRefs: memberPicker.members.map(\.memberRef),
                description: NewChatSheet.normalizedGroupDescription(groupDescription)
            )
            Haptics.success()
            dismiss()
            appState.presentChat(groupIdHex: groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the sheet open and name who can't be added.
                memberPicker.error = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be added yet.",
                    IdentityFormatter.short(account)
                )
            } else {
                memberPicker.error = marmotError.localizedDescription
                appState.present(.error(L10n.string("Couldn't create chat"), message: marmotError.localizedDescription))
            }
        } catch {
            Haptics.error()
            memberPicker.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't create chat"), message: error.localizedDescription))
        }
        isCreating = false
    }

    private func normalize(using appState: AppState) -> MemberPickerViewModel.Normalize {
        { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) }
    }

    private func warmProfile(using appState: AppState) -> MemberPickerViewModel.ProfileWarmup {
        { _ = appState.profile(forAccountIdHex: $0) }
    }
}

import Foundation
import MarmotKit

/// Screen store for `AddMembersSheet`: owns invite flow and delegates member
/// collection to the shared picker also used by new-chat.
@MainActor
@Observable
final class AddMembersSheetViewModel {
    let memberPicker = MemberPickerViewModel()
    var isInviting = false

    func invite(
        normalize: @escaping MemberPickerViewModel.Normalize,
        onSubmit: ([String]) async throws -> Void,
        using appState: AppState,
        dismiss: () -> Void
    ) async {
        // Take the in-flight guard synchronously before the first await so a
        // fast double-tap can't start two concurrent invite tasks while the
        // off-main member normalization is still in flight (#260/#274).
        guard !isInviting else { return }
        isInviting = true
        // Fold the still-in-field text before clearing any prior validation error
        // (`addPending` sets its own error on invalid input). The in-flight guard
        // stays ahead of the await so a double-tap can't start two invites.
        guard await memberPicker.addPending(normalize: normalize, warmProfile: warmProfile(using: appState)) else {
            isInviting = false
            return
        }
        guard !memberPicker.members.isEmpty else {
            isInviting = false
            return
        }
        memberPicker.error = nil
        do {
            try await onSubmit(memberPicker.members.map(\.memberRef))
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            memberPicker.error = error.localizedDescription
        }
    }

    private func warmProfile(using appState: AppState) -> MemberPickerViewModel.ProfileWarmup {
        { _ = appState.profile(forAccountIdHex: $0) }
    }
}

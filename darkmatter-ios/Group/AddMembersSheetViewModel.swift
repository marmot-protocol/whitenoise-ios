import Foundation
import MarmotKit

/// Screen store for `AddMembersSheet`: owns invite flow and delegates recipient
/// staging to the shared model also used by new-chat.
@MainActor
@Observable
final class AddMembersSheetViewModel {
    let recipients = RecipientStagingModel()
    var isInviting = false

    @discardableResult
    func add(
        _ raw: String,
        normalize: @escaping RecipientStagingModel.Normalize,
        using appState: AppState
    ) async -> Bool {
        await recipients.add(raw, normalize: normalize, warmProfile: warmProfile(using: appState))
    }

    @discardableResult
    func addPending(normalize: @escaping RecipientStagingModel.Normalize, using appState: AppState) async -> Bool {
        await recipients.addPending(normalize: normalize, warmProfile: warmProfile(using: appState))
    }

    func addScanned(_ raw: String, normalize: @escaping RecipientStagingModel.Normalize, using appState: AppState) {
        Task { await add(raw, normalize: normalize, using: appState) }
    }

    func invite(
        normalize: @escaping RecipientStagingModel.Normalize,
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
        guard !recipients.members.isEmpty else {
            isInviting = false
            return
        }
        recipients.error = nil
        do {
            try await onSubmit(recipients.members.map(\.memberRef))
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            recipients.error = error.localizedDescription
        }
    }

    private func warmProfile(using appState: AppState) -> RecipientStagingModel.ProfileWarmup {
        { _ = appState.profile(forAccountIdHex: $0) }
    }
}

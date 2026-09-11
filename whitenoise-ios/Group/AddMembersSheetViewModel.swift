import Foundation
import MarmotKit

/// Screen store for `AddMembersSheet`: the people directory, the search
/// query, the multi-select, and the invite submission.
@MainActor
@Observable
final class AddMembersSheetViewModel {
    let directory = RecipientDirectory()
    let query = RecipientQueryModel()
    let userSearch = RecipientUserSearch()
    let selection = RecipientSelection()
    var isInviting = false
    var error: String?
    @ObservationIgnored private let keyPackagePrewarmer = MemberKeyPackagePrewarmer()

    @discardableResult
    func toggle(_ candidate: RecipientCandidate, excludedAccountIds: Set<String>) -> Bool {
        let didChange = selection.toggle(
            RecipientSelection.member(for: candidate),
            excludedAccountIds: excludedAccountIds
        )
        if selection.isSelected(accountIdHex: candidate.accountIdHex) {
            query.clear()
        }
        return didChange
    }

    @discardableResult
    func remove(accountIdHex: String) -> Bool {
        let previousCount = selection.count
        selection.remove(accountIdHex: accountIdHex)
        return selection.count != previousCount
    }

    /// Coalesces changes and avoids repeating relay lookups for the same selection.
    func scheduleMemberKeyPackagePrewarm(
        accountRef: String? = nil,
        runtimeGeneration: Int = 0,
        debounce: Duration = .milliseconds(250),
        prewarm: @escaping @MainActor ([String]) async -> Void
    ) {
        keyPackagePrewarmer.schedule(
            memberRefs: selection.memberRefs, accountRef: accountRef,
            runtimeGeneration: runtimeGeneration, debounce: debounce, prewarm: prewarm
        )
    }

    func cancelMemberKeyPackagePrewarm() {
        keyPackagePrewarmer.cancel()
    }

    /// Normalizes a resolved identifier through Marmot before selecting it so
    /// the staged member carries the validated reference form.
    @discardableResult
    func selectResolved(
        _ resolved: ResolvedRecipient,
        excludedAccountIds: Set<String>,
        normalize: (String) async throws -> MemberRefFfi
    ) async -> Bool {
        guard !isInviting else { return false }
        let result = await AddMembersPresentation.normalizedMember(
            resolved.memberRef,
            normalize: normalize
        )
        // Re-check after the await: a selection resumed mid-submit would
        // stage a recipient the in-flight invite never sends.
        guard !isInviting else { return false }
        guard case .normalized(let member) = result else { return false }
        if selection.add(member, excludedAccountIds: excludedAccountIds) {
            Haptics.selection()
            query.clear()
            return true
        }
        return false
    }

    func invite(
        onSubmit: ([String]) async throws -> Void,
        dismiss: () -> Void
    ) async {
        // The in-flight guard is taken synchronously before the first await
        // so a fast double-tap can't start two concurrent invite tasks.
        guard !isInviting, !selection.isEmpty else { return }
        isInviting = true
        error = nil
        do {
            try await onSubmit(selection.memberRefs)
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            self.error = UserFacingError.message(for: error)
        }
    }
}

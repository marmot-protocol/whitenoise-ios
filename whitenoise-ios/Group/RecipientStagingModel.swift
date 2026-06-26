import Foundation
import MarmotKit

/// Shared recipient-staging state machine for sheets that collect profile
/// references before submitting a group mutation. Normalization stays off the
/// MainActor; staging runs after the await against the live member list so
/// duplicate checks see concurrent additions.
@MainActor
@Observable
final class RecipientStagingModel {
    typealias Normalize = (String) async throws -> MemberRefFfi
    typealias ProfileWarmup = (String) -> Void

    var members: [MemberRefFfi] = []
    var pending = ""
    var error: String?
    var showScanner = false

    // Guards the silent auto-stage path so rapid `pending` changes can't spawn
    // overlapping off-main normalizations for the same input.
    private var isAutoStaging = false

    static var defaultInvalidMessage: String {
        L10n.string("Enter a valid npub, nprofile, Nostr URI, profile link, or hex public key.")
    }

    @discardableResult
    func addPending(
        invalidMessage: String? = nil,
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async -> Bool {
        await add(pending, invalidMessage: invalidMessage, normalize: normalize, warmProfile: warmProfile)
    }

    /// Silent auto-stage for the input field: stages `pending` only when it
    /// already parses to a complete, valid reference, and never surfaces an
    /// error (the explicit "+" button and return key own invalid-input
    /// feedback). Reentrancy-guarded so a burst of input changes can't start
    /// overlapping normalizations; a rare Marmot failure on a locally-valid
    /// reference leaves the text in place for the user to retry explicitly.
    func autoStagePendingIfComplete(
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async {
        let raw = pending
        guard AddMembersPresentation.isCompleteReference(raw) else { return }
        guard !isAutoStaging else { return }
        isAutoStaging = true
        defer { isAutoStaging = false }
        let previousError = error
        let added = await add(raw, normalize: normalize, warmProfile: warmProfile)
        if !added { error = previousError }
    }

    @discardableResult
    func addScanned(
        _ raw: String,
        invalidMessage: String? = nil,
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async -> Bool {
        await add(raw, invalidMessage: invalidMessage, normalize: normalize, warmProfile: warmProfile)
    }

    @discardableResult
    func add(
        _ raw: String,
        invalidMessage: String? = nil,
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async -> Bool {
        let normalizedResult = await AddMembersPresentation.normalizedMember(raw, normalize: normalize)
        switch normalizedResult {
        case .empty:
            return true
        case .invalid:
            Haptics.error()
            error = invalidMessage ?? Self.defaultInvalidMessage
            return false
        case .normalized(let normalized):
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
                warmProfile(addedMember.accountIdHex)
                return true
            }
        }
    }

    func clearPendingIfUnchanged(_ raw: String) {
        if pending == raw {
            pending = ""
        }
    }
}

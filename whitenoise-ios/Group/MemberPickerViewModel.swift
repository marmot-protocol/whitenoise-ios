import Foundation
import MarmotKit

/// Shared member picker for sheets that collect profile references before
/// submitting a group mutation. Normalization stays off the MainActor; the
/// member append runs after the await against the live list so duplicate checks
/// see concurrent additions.
@MainActor
@Observable
final class MemberPickerViewModel {
    typealias Normalize = (String) async throws -> MemberRefFfi
    typealias ProfileWarmup = (String) -> Void

    var members: [MemberRefFfi] = []
    var pending = ""
    var error: String?
    var showScanner = false

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
    /// feedback). Concurrent auto-stages are safe — staging dedups by
    /// `accountIdHex` against the live member list after the await — and a rare
    /// Marmot failure on a locally-valid reference leaves the text in place for
    /// the user to retry explicitly.
    func autoStagePendingIfComplete(
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async {
        let raw = pending
        guard AddMembersPresentation.isCompleteReference(raw) else { return }
        await add(raw, suppressInvalidFeedback: true, normalize: normalize, warmProfile: warmProfile)
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
        suppressInvalidFeedback: Bool = false,
        normalize: Normalize,
        warmProfile: ProfileWarmup = { _ in }
    ) async -> Bool {
        let normalizedResult = await AddMembersPresentation.normalizedMember(raw, normalize: normalize)
        switch normalizedResult {
        case .empty:
            return true
        case .invalid:
            // The silent auto-stage path owns no invalid feedback; only the
            // explicit "+" button and return key buzz and surface an error.
            if !suppressInvalidFeedback {
                Haptics.error()
                error = invalidMessage ?? Self.defaultInvalidMessage
            }
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

    /// Unstage a member, matching by `accountIdHex` so it pairs with the
    /// dedup rule used when adding.
    func remove(_ member: MemberRefFfi) {
        members.removeAll { $0.accountIdHex == member.accountIdHex }
    }

    func clearPendingIfUnchanged(_ raw: String) {
        if pending == raw {
            pending = ""
        }
    }
}

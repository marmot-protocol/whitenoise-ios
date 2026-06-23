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

@testable import whitenoise_ios
import Foundation
import MarmotKit
import Testing

/// Stands in for the Marmot calls a `GroupDetailsViewModel` makes. Tests replace
/// any call at any point; a call the test didn't set records an issue.
@MainActor
final class GroupDetailsMarmotDouble {
    var updateGroupProfile: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ name: String, _ description: String
    ) async throws -> SendSummaryFfi = { _, _, _, _ in
        Issue.record("unexpected group profile update")
        return SendSummaryFfi(published: 0, messageIds: [])
    }

    var updateGroupAvatarUrl: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ url: String?
    ) async throws -> SendSummaryFfi = { _, _, _ in
        Issue.record("unexpected group avatar URL update")
        return SendSummaryFfi(published: 0, messageIds: [])
    }

    var updateGroupImage: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ plaintext: Data, _ mediaType: String
    ) async throws -> SendSummaryFfi = { _, _, _, _ in
        Issue.record("unexpected group image update")
        return SendSummaryFfi(published: 0, messageIds: [])
    }

    var clearGroupImage: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> SendSummaryFfi = { _, _ in
        Issue.record("unexpected group image clear")
        return SendSummaryFfi(published: 0, messageIds: [])
    }

    /// The shared media the read returns.
    var sharedMedia: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> [MediaRecordFfi] = { _, _ in
        Issue.record("unexpected shared media read")
        return []
    }

    var setGroupArchived: @MainActor (
        _ accountRef: String, _ groupIdHex: String, _ archived: Bool
    ) async throws -> AppGroupRecordFfi = { _, _, _ in
        Issue.record("unexpected archive change")
        throw CancellationError()
    }

    var leaveGroup: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> SendSummaryFfi = { _, _ in
        Issue.record("unexpected leave")
        return SendSummaryFfi(published: 0, messageIds: [])
    }

    var enableGroupDisbanding: @MainActor (
        _ accountRef: String, _ groupIdHex: String
    ) async throws -> GroupMutationResultFfi = { _, _ in
        Issue.record("unexpected disbanding enable")
        throw CancellationError()
    }

    var disbandGroup: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> DisbandRequestFfi = { _, _ in
        Issue.record("unexpected disband")
        return .pending(requestedAtMs: 0)
    }

    var acknowledgeDisbandFailure: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> Bool = { _, _ in
        Issue.record("unexpected disband failure acknowledgement")
        return false
    }

    var forgetGroupLocal: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> Bool = { _, _ in
        Issue.record("unexpected local group reset")
        return false
    }

    /// Whether clearing decrypted media after a reset cleared everything.
    var clearResetMedia: @MainActor () async -> Bool = {
        Issue.record("unexpected media clear")
        return true
    }

    var cancelLeave: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> Void = { _, _ in
        Issue.record("unexpected leave cancellation")
    }

    var deleteGroupLocal: @MainActor (_ accountRef: String, _ groupIdHex: String) async throws -> Bool = { _, _ in
        Issue.record("unexpected local group delete")
        return false
    }
}

/// A group-details model whose Marmot calls go to `marmot`.
@MainActor
func groupDetailsModel(marmot: GroupDetailsMarmotDouble) -> GroupDetailsViewModel {
    GroupDetailsViewModel(marmotCalls: GroupDetailsMarmotCalls(
        updateGroupProfile: { _, accountRef, groupIdHex, name, description in
            try await marmot.updateGroupProfile(accountRef, groupIdHex, name, description)
        },
        updateGroupAvatarUrl: { _, accountRef, groupIdHex, url in
            try await marmot.updateGroupAvatarUrl(accountRef, groupIdHex, url)
        },
        updateGroupImage: { _, accountRef, groupIdHex, plaintext, mediaType in
            try await marmot.updateGroupImage(accountRef, groupIdHex, plaintext, mediaType)
        },
        clearGroupImage: { _, accountRef, groupIdHex in
            try await marmot.clearGroupImage(accountRef, groupIdHex)
        },
        sharedMedia: { _, accountRef, groupIdHex in
            (GroupSharedMediaPresentation.items(from: try await marmot.sharedMedia(accountRef, groupIdHex)), nil)
        },
        setGroupArchived: { _, accountRef, groupIdHex, archived in
            try await marmot.setGroupArchived(accountRef, groupIdHex, archived)
        },
        leaveGroup: { _, accountRef, groupIdHex in try await marmot.leaveGroup(accountRef, groupIdHex) },
        enableGroupDisbanding: { _, accountRef, groupIdHex in
            try await marmot.enableGroupDisbanding(accountRef, groupIdHex)
        },
        disbandGroup: { _, accountRef, groupIdHex in try await marmot.disbandGroup(accountRef, groupIdHex) },
        acknowledgeDisbandFailure: { _, accountRef, groupIdHex in
            try await marmot.acknowledgeDisbandFailure(accountRef, groupIdHex)
        },
        forgetGroupLocal: { _, accountRef, groupIdHex in try await marmot.forgetGroupLocal(accountRef, groupIdHex) },
        clearResetMedia: { await marmot.clearResetMedia() },
        deleteGroupLocal: { _, accountRef, groupIdHex in try await marmot.deleteGroupLocal(accountRef, groupIdHex) },
        cancelLeave: { _, accountRef, groupIdHex in
            try await marmot.cancelLeave(accountRef, groupIdHex)
        }
    ))
}

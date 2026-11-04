@testable import whitenoise_ios
import Foundation
import MarmotKit
import Testing

/// Stands in for the Marmot calls a `GroupDetailsViewModel` makes to publish the
/// group's info and image and to read its shared media. Tests replace any call
/// at any point; a call the test didn't set records an issue.
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
}

/// A group-details model whose info, image and shared-media calls go to `marmot`.
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
        }
    ))
}

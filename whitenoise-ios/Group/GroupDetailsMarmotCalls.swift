import Foundation
import MarmotKit

/// The Marmot calls `GroupDetailsViewModel` makes to publish the group's name,
/// description and image and to read its shared media. Each takes the runtime
/// client its call site resolved.
struct GroupDetailsMarmotCalls {
    var updateGroupProfile: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String, _ name: String, _ description: String
    ) async throws -> SendSummaryFfi
    var updateGroupAvatarUrl: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String, _ url: String?
    ) async throws -> SendSummaryFfi
    var updateGroupImage: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String, _ plaintext: Data, _ mediaType: String
    ) async throws -> SendSummaryFfi
    var clearGroupImage: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String
    ) async throws -> SendSummaryFfi
    /// The first page of shared media, and the history version it was read at.
    var sharedMedia: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String
    ) async throws -> (items: [GroupSharedMediaItem], version: AttachmentHistoryVersion?)

    static let marmot = GroupDetailsMarmotCalls(
        updateGroupProfile: { client, accountRef, groupIdHex, name, description in
            try await client.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                name: name,
                description: description
            )
        },
        updateGroupAvatarUrl: { client, accountRef, groupIdHex, url in
            try await client.updateGroupAvatarUrl(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                url: url,
                dim: nil,
                thumbhash: nil
            )
        },
        updateGroupImage: { client, accountRef, groupIdHex, plaintext, mediaType in
            try await client.updateGroupImage(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                plaintext: plaintext,
                mediaType: mediaType
            )
        },
        clearGroupImage: { client, accountRef, groupIdHex in
            try await client.clearGroupImage(accountRef: accountRef, groupIdHex: groupIdHex)
        },
        sharedMedia: { client, accountRef, groupIdHex in
            let page = try await client.attachmentPreview(accountRef: accountRef, groupID: groupIdHex)
            return (GroupSharedMediaPresentation.items(entries: page.entries), page.version)
        }
    )
}

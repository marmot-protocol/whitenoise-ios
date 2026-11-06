import Foundation
import MarmotKit

/// The Marmot calls `GroupDetailsViewModel` makes. Most take the runtime client
/// their call site resolved; the ones that take `AppState` resolve it themselves,
/// right before the call, as their call sites did.
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
    var setGroupArchived: @MainActor (
        AppState, _ accountRef: String, _ groupIdHex: String, _ archived: Bool
    ) async throws -> AppGroupRecordFfi
    var leaveGroup: @MainActor (MarmotClient, _ accountRef: String, _ groupIdHex: String) async throws -> SendSummaryFfi
    var enableGroupDisbanding: @MainActor (
        MarmotClient, _ accountRef: String, _ groupIdHex: String
    ) async throws -> GroupMutationResultFfi
    var disbandGroup: @MainActor (MarmotClient, _ accountRef: String, _ groupIdHex: String) async throws -> DisbandRequestFfi
    var acknowledgeDisbandFailure: @MainActor (AppState, _ accountRef: String, _ groupIdHex: String) async throws -> Bool
    var forgetGroupLocal: @MainActor (MarmotClient, _ accountRef: String, _ groupIdHex: String) async throws -> Bool
    /// Clears every decrypted media file after a local group reset; false if some remain.
    var clearResetMedia: @MainActor () async -> Bool
    var deleteGroupLocal: @MainActor (AppState, _ accountRef: String, _ groupIdHex: String) async throws -> Bool

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
        },
        setGroupArchived: { appState, accountRef, groupIdHex, archived in
            try await appState.currentMarmotClient().setGroupArchived(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                archived: archived
            )
        },
        leaveGroup: { client, accountRef, groupIdHex in
            try await client.leaveGroup(accountRef: accountRef, groupIdHex: groupIdHex)
        },
        enableGroupDisbanding: { client, accountRef, groupIdHex in
            try await client.enableGroupDisbanding(accountRef: accountRef, groupIdHex: groupIdHex)
        },
        disbandGroup: { client, accountRef, groupIdHex in
            try await client.disbandGroup(accountRef: accountRef, groupIdHex: groupIdHex)
        },
        acknowledgeDisbandFailure: { appState, accountRef, groupIdHex in
            try await appState.currentMarmotClient().acknowledgeDisbandFailure(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
        },
        forgetGroupLocal: { client, accountRef, groupIdHex in
            try await client.forgetGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
        },
        clearResetMedia: {
            await MessageMediaCache.purgeAllDecryptedMedia()
        },
        deleteGroupLocal: { appState, accountRef, groupIdHex in
            try await appState.currentMarmotClient().deleteGroupLocal(accountRef: accountRef, groupIdHex: groupIdHex)
        }
    )
}

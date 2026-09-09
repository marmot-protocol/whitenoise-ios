import SwiftUI
import MarmotKit

/// Screen store for `GroupDetailsView` (a conversation sub-view): owns the local
/// UI/action state and the group-management + transcript-export + debug-refresh
/// orchestration, so the view is pure rendering. The domain data still comes from
/// the `ConversationViewModel`, which this holds (bound at the top of the view's
/// body, alongside the `onGroupChanged` callback); `AppState` is passed into the
/// methods, and `leave` also takes the view's `dismiss`. The tested
/// `validatedGroupName` static stays on the view; `rename` calls it.
@MainActor
@Observable
final class GroupDetailsViewModel {
    var showAddMembers = false
    var showProfileEditor = false
    var showGroupImageEditor = false
    var showRetentionEditor = false
    var renameDraft = ""
    var descriptionDraft = ""
    var actionError: String?
    var mlsState: AppGroupMlsStateFfi?
    var pushDebugInfo: GroupPushDebugInfoFfi?
    var pushDebugError: String?
    var maintenanceStatus: GroupMaintenanceStatusFfi?
    var maintenanceStatusError: String?
    var pendingConfirmation: GroupDetailsConfirmation?
    var membershipActionInFlight = false
    var isExportingTranscript = false
    var transcriptExportURL: URL?
    var showTranscriptShareSheet = false
    var transcriptExportError: String?
    var sharedMediaRecords: [MediaRecordFfi] = []
    var isLoadingSharedMedia = false
    var sharedMediaError: String?
    var notifyMode: ChatNotifyMode = .all
    var isMuted: Bool { notifyMode == .nothing }
    private(set) var sharedGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var addableGroups: [SharedGroupsProjection.SharedGroup] = []
    private let recipientDirectory = RecipientDirectory()
    private var didLoadSharedMedia = false
    private var pendingLegacyAvatarClearAfterImageMutation = false

    // Bound by the view at the top of `body` (both @ObservationIgnored, so the
    // assignment never triggers a re-render). `conversation` is therefore set
    // before any method runs.
    @ObservationIgnored var conversation: ConversationViewModel?
    @ObservationIgnored var onGroupChanged: (AppGroupRecordFfi) -> Void = { _ in }
    @ObservationIgnored var onGroupLeft: (String) -> Void = { _ in }
    @ObservationIgnored var onGroupDeleted: (String) -> Void = { _ in }
#if DEBUG
    @ObservationIgnored var setGroupArchivedForTesting: (@MainActor (String, String, Bool) async throws -> AppGroupRecordFfi)?
    @ObservationIgnored var updateGroupProfileForTesting: (@MainActor (String, String, String, String) async throws -> SendSummaryFfi)?
    @ObservationIgnored var updateGroupAvatarUrlForTesting: (@MainActor (String, String, String?) async throws -> SendSummaryFfi)?
    @ObservationIgnored var updateGroupImageForTesting: (@MainActor (String, String, Data, String) async throws -> SendSummaryFfi)?
    @ObservationIgnored var clearGroupImageForTesting: (@MainActor (String, String) async throws -> SendSummaryFfi)?
    @ObservationIgnored var listMediaForTesting: (@MainActor (String, String) async throws -> [MediaRecordFfi])?
    @ObservationIgnored var leaveGroupForTesting: (@MainActor (String, String) async throws -> SendSummaryFfi)?
    @ObservationIgnored var deleteGroupLocalForTesting: (@MainActor (String, String) async throws -> Bool)?
    @ObservationIgnored var enableGroupDisbandingForTesting: (@MainActor (String, String) async throws -> GroupMutationResultFfi)?
    @ObservationIgnored var disbandGroupForTesting: (@MainActor (String, String) async throws -> DisbandRequestFfi)?
    @ObservationIgnored var acknowledgeDisbandFailureForTesting: (@MainActor (String, String) async throws -> Bool)?
#endif

    isolated deinit {
        cleanupTranscriptExportFile()
    }

    func invite(refs: [String], using appState: AppState) async throws {
        guard let conversation, let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        // Throwing keeps the caller from treating a skipped invite as success
        // (the sheet would dismiss and drop the staged selection).
        guard !membershipActionInFlight else { throw GroupDetailsActionError.operationInFlight }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            let client = try appState.currentMarmotClient()
            appState.present(.warning(L10n.string("Inviting members…"), message: L10n.string("Publishing group update.")))
            let result = try await client.inviteMembersDetailed(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                memberRefs: refs
            )
            conversation.applyGroupMutation(result)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.success(
                L10n.plural("Invited %lld members", Int64(refs.count)),
                message: publishMessage(for: result.summary)
            ))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Invite failed"), using: appState)
            throw error
        }
    }

    func remove(member: GroupMemberDetailsFfi, using appState: AppState) async {
        pendingConfirmation = nil
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            let client = try appState.currentMarmotClient()
            appState.present(.warning(L10n.string("Removing member…"), message: L10n.string("Publishing group update.")))
            let result = try await client.removeMembersDetailed(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                memberRefs: [member.memberIdHex]
            )
            conversation.applyGroupMutation(result)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.warning(L10n.string("Member removed"), message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't remove member"), using: appState)
        }
    }

    func setAdmin(member: GroupMemberDetailsFfi, admin: Bool, using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        conversation.applyOptimisticAdminStatus(memberIdHex: member.memberIdHex, isAdmin: admin)
        appState.present(.warning(
            admin ? L10n.string("Making admin…") : L10n.string("Removing admin…"),
            message: L10n.string("Publishing group update.")
        ))
        do {
            let client = try appState.currentMarmotClient()
            let result: GroupMutationResultFfi
            if admin {
                result = try await client.promoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            } else {
                result = try await client.demoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            }
            conversation.applyGroupMutation(result)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(
                admin
                    ? .success(L10n.string("Made admin"), message: publishMessage(for: result.summary))
                    : .warning(L10n.string("Admin removed"), message: publishMessage(for: result.summary))
            )
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't change admin"), using: appState)
        }
    }

    func selfDemote(using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        if let myAccountId = conversation.managementState?.myAccountIdHex {
            conversation.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
        }
        appState.present(.warning(L10n.string("Stepping down…"), message: L10n.string("Publishing group update.")))
        do {
            let client = try appState.currentMarmotClient()
            let result = try await client.selfDemoteAdminDetailed(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex
            )
            conversation.applyGroupMutation(result)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.warning(L10n.string("You stepped down as admin"), message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't step down"), using: appState)
        }
    }

    func prepareProfileDrafts() {
        guard let conversation else { return }
        renameDraft = ContentSanitizer.groupName(conversation.group.name) ?? ""
        descriptionDraft = GroupDetailsView.normalizedGroupDescriptionForUpdate(
            conversation.group.description
        )
    }

    @discardableResult
    func updateProfile(using appState: AppState) async -> Bool {
        guard let conversation, let accountRef = appState.activeAccountRef,
              let name = GroupDetailsView.validatedGroupName(renameDraft) else { return false }
        let description = GroupDetailsView.normalizedGroupDescriptionForUpdate(descriptionDraft)
        let currentName = ContentSanitizer.groupName(conversation.group.name) ?? ""
        let currentDescription = GroupDetailsView.normalizedGroupDescriptionForUpdate(
            conversation.group.description
        )
        guard name != currentName || description != currentDescription else { return true }
        guard !membershipActionInFlight else { return false }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(L10n.string("Updating group info…"), message: L10n.string("Publishing group update.")))
            let summary: SendSummaryFfi
#if DEBUG
            if let updateGroupProfileForTesting {
                summary = try await updateGroupProfileForTesting(
                    accountRef,
                    conversation.group.groupIdHex,
                    name,
                    description
                )
            } else {
                let client = try appState.currentMarmotClient()
                summary = try await client.updateGroupProfile(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    name: name,
                    description: description
                )
            }
#else
            let client = try appState.currentMarmotClient()
            summary = try await client.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                name: name,
                description: description
            )
#endif
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.success(L10n.string("Group info updated"), message: publishMessage(for: summary)))
            return true
        } catch {
            await refreshAfterFailedMutation(using: appState)
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't update group info"), error: error))
            return false
        }
    }

    func loadSharedMedia(using appState: AppState, force: Bool = false) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard !isLoadingSharedMedia, force || !didLoadSharedMedia else { return }
        isLoadingSharedMedia = true
        sharedMediaError = nil
        defer { isLoadingSharedMedia = false }

        do {
            let records: [MediaRecordFfi]
#if DEBUG
            if let listMediaForTesting {
                records = try await listMediaForTesting(accountRef, conversation.group.groupIdHex)
            } else {
                let client = try appState.currentMarmotClient()
                records = try await client.listMedia(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex
                )
            }
#else
            let client = try appState.currentMarmotClient()
            records = try await client.listMedia(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex
            )
#endif
            try Task.checkCancellation()
            sharedMediaRecords = records
            didLoadSharedMedia = true
        } catch is CancellationError {
            return
        } catch {
            sharedMediaError = L10n.string("Couldn't load shared media.")
        }
    }

    func updateGroupImage(
        draft: GroupImageUploadDraft?,
        using appState: AppState,
        onProgress: (GroupImageProgressPhase?) -> Void = { _ in }
    ) async throws {
        guard let conversation, let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        guard !membershipActionInFlight else { throw GroupDetailsActionError.operationInFlight }
        let replacingImageHashHex = conversation.group.imageHashHex
        membershipActionInFlight = true
        onProgress(.updating)
        defer { membershipActionInFlight = false }

        do {
            let client = try appState.currentMarmotClient()
            var summary: SendSummaryFfi?
            var publishedEncryptedImage = false
#if DEBUG
            if let draft {
                if !pendingLegacyAvatarClearAfterImageMutation {
                    if let updateGroupImageForTesting {
                        summary = try await updateGroupImageForTesting(
                            accountRef,
                            conversation.group.groupIdHex,
                            draft.data,
                            draft.mediaType
                        )
                    } else {
                        summary = try await client.updateGroupImage(
                            accountRef: accountRef,
                            groupIdHex: conversation.group.groupIdHex,
                            plaintext: draft.data,
                            mediaType: draft.mediaType
                        )
                    }
                    publishedEncryptedImage = true
                }
            } else if conversation.group.imageHashHex != nil,
                      !pendingLegacyAvatarClearAfterImageMutation {
                if let clearGroupImageForTesting {
                    summary = try await clearGroupImageForTesting(
                        accountRef,
                        conversation.group.groupIdHex
                    )
                } else {
                    summary = try await client.clearGroupImage(
                        accountRef: accountRef,
                        groupIdHex: conversation.group.groupIdHex
                    )
                }
            }
#else
            if let draft {
                if !pendingLegacyAvatarClearAfterImageMutation {
                    summary = try await client.updateGroupImage(
                        accountRef: accountRef,
                        groupIdHex: conversation.group.groupIdHex,
                        plaintext: draft.data,
                        mediaType: draft.mediaType
                    )
                    publishedEncryptedImage = true
                }
            } else if conversation.group.imageHashHex != nil,
                      !pendingLegacyAvatarClearAfterImageMutation {
                summary = try await client.clearGroupImage(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex
                )
            }
#endif

            onProgress(.finishing)

            // URL avatars win over encrypted Blossom images in Marmot's
            // projection. Clear a legacy URL only after the replacement
            // upload succeeds, so a partial migration keeps the old image.
            if conversation.group.avatarUrl != nil {
                pendingLegacyAvatarClearAfterImageMutation = true
#if DEBUG
                if let updateGroupAvatarUrlForTesting {
                    summary = try await updateGroupAvatarUrlForTesting(
                        accountRef,
                        conversation.group.groupIdHex,
                        nil
                    )
                } else {
                    summary = try await client.updateGroupAvatarUrl(
                        accountRef: accountRef,
                        groupIdHex: conversation.group.groupIdHex,
                        url: nil,
                        dim: nil,
                        thumbhash: nil
                    )
                }
#else
                summary = try await client.updateGroupAvatarUrl(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    url: nil,
                    dim: nil,
                    thumbhash: nil
                )
#endif
                pendingLegacyAvatarClearAfterImageMutation = false
            } else if pendingLegacyAvatarClearAfterImageMutation {
                pendingLegacyAvatarClearAfterImageMutation = false
            }

            if let summary {
                if let draft {
                    GroupAvatarImageLoader.seed(
                        data: draft.data,
                        accountRef: accountRef,
                        groupIdHex: conversation.group.groupIdHex,
                        replacingImageHashHex: publishedEncryptedImage ? replacingImageHashHex : nil
                    )
                }
                await refreshGroupManagementAndNotify()
                await refreshVisibleDebugState(using: appState)
                Haptics.success()
                onProgress(nil)
                appState.present(.success(
                    draft == nil ? L10n.string("Group image removed") : L10n.string("Group image updated"),
                    message: publishMessage(for: summary)
                ))
            } else {
                onProgress(nil)
            }
        } catch {
            onProgress(.finishing)
            await refreshAfterFailedMutation(using: appState)
            Haptics.error()
            actionError = error.localizedDescription
            onProgress(nil)
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't update group image"), error: error))
            throw error
        }
    }

    /// Publishes a new disappearing-messages retention. The engine prunes
    /// retroactively on enable/shorten, so the timeline window is reloaded
    /// after the group state refresh to evict any locally pruned rows.
    @discardableResult
    func updateRetention(seconds: UInt64, using appState: AppState) async -> Bool {
        guard let conversation, let accountRef = appState.activeAccountRef else { return false }
        guard seconds != conversation.group.disappearingMessageSecs else { return true }
        guard !membershipActionInFlight else { return false }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(
                L10n.string("Updating disappearing messages…"),
                message: L10n.string("Publishing group update.")
            ))
            let client = try appState.currentMarmotClient()
            let summary = try await client.updateMessageRetention(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                disappearingMessageSecs: seconds
            )
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState(using: appState)
            await conversation.refreshTimelineWindowAfterLocalPrune()
            Haptics.success()
            appState.present(.success(
                L10n.string("Disappearing messages updated"),
                message: publishMessage(for: summary)
            ))
            return true
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't update disappearing messages"), using: appState)
            return false
        }
    }

    /// Direct-chat details show every group both people share, including this
    /// direct-message chat, derived from the recipient directory snapshots.
    func loadSharedGroups(using appState: AppState, force: Bool = false) async {
        guard let conversation, conversation.groupDisplay.isDirectMessage,
              let otherMember = conversation.otherMember
        else {
            sharedGroups = []
            addableGroups = []
            return
        }
        await recipientDirectory.load(
            using: appState,
            force: force,
            includeAdminMetadata: true
        )
        guard !Task.isCancelled else { return }
        sharedGroups = SharedGroupsProjection.sharedGroups(
            snapshots: recipientDirectory.snapshots,
            targetAccountIdHex: otherMember,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
        addableGroups = SharedGroupsProjection.addableGroups(
            snapshots: recipientDirectory.snapshots,
            targetAccountIdHex: otherMember,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    func loadMuteState(using appState: AppState) {
        guard let conversation,
              let accountIdHex = appState.activeAccount?.accountIdHex
        else { return }
        notifyMode = ChatMuteStore.notifyMode(
            accountIdHex: accountIdHex,
            groupIdHex: conversation.group.groupIdHex
        )
    }

    /// The notify mode is a local, per-device preference; unlike archive it
    /// publishes nothing and doesn't touch the group record.
    func setNotifyMode(_ mode: ChatNotifyMode, using appState: AppState) {
        guard let conversation,
              let accountIdHex = appState.activeAccount?.accountIdHex
        else { return }
        ChatMuteStore.setNotifyMode(
            mode,
            accountIdHex: accountIdHex,
            groupIdHex: conversation.group.groupIdHex
        )
        notifyMode = mode
        Haptics.success()
    }

    /// The quick-action Mute button toggles between the tri-state's ends; a
    /// mentions-only chat mutes from here and unmutes back to all messages.
    func setMuted(_ muted: Bool, using appState: AppState) {
        setNotifyMode(muted ? .nothing : .all, using: appState)
        guard let conversation else { return }
        let isDirectMessage = conversation.groupDisplay.isDirectMessage
        let mutedTitle = isDirectMessage ? L10n.string("Chat muted") : L10n.string("Group muted")
        let unmutedTitle = isDirectMessage ? L10n.string("Chat unmuted") : L10n.string("Group unmuted")
        appState.present(muted ? .warning(mutedTitle) : .success(unmutedTitle))
    }

    func setArchived(_ archived: Bool, using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            let record: AppGroupRecordFfi
#if DEBUG
            if let setGroupArchivedForTesting {
                record = try await setGroupArchivedForTesting(
                    accountRef,
                    conversation.group.groupIdHex,
                    archived
                )
            } else {
                let client = try appState.currentMarmotClient()
                record = try await client.setGroupArchived(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    archived: archived
                )
            }
#else
            let client = try appState.currentMarmotClient()
            record = try await client.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                archived: archived
            )
#endif
            conversation.applyGroupRecord(record)
            onGroupChanged(record)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(archived ? .warning(L10n.string("Group archived")) : .success(L10n.string("Group unarchived")))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't update archive"), error: error))
        }
    }

    func leave(using appState: AppState, dismiss: () -> Void) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard GroupManagementPresentation.canLeave(
            state: conversation.managementState,
            fallbackIsLastAdmin: conversation.isLastAdmin
        ) else {
            actionError = GroupManagementPresentation.leaveFooter(
                state: conversation.managementState,
                fallbackIsLastAdmin: conversation.isLastAdmin
            )
            return
        }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            let groupIdHex = conversation.group.groupIdHex
            let client = try appState.currentMarmotClient()
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: conversation.managementState) {
                if let myAccountId = conversation.managementState?.myAccountIdHex {
                    conversation.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
                }
                appState.present(.warning(L10n.string("Stepping down before leaving…"), message: L10n.string("Publishing group update.")))
                let result = try await client.selfDemoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex
                )
                conversation.applyGroupMutation(result)
                await refreshVisibleDebugState(using: appState)
            }
            appState.present(.warning(L10n.string("Leaving group…"), message: L10n.string("Publishing group update.")))
#if DEBUG
            if let leaveGroupForTesting {
                _ = try await leaveGroupForTesting(accountRef, groupIdHex)
            } else {
                _ = try await client.leaveGroup(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            }
#else
            _ = try await client.leaveGroup(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
#endif
            conversation.markSelfLeft()
            onGroupChanged(conversation.group)
            Haptics.warning()
            appState.present(.warning(L10n.string("You left the group")))
            dismiss()
            onGroupLeft(groupIdHex)
        } catch {
            await refreshAfterFailedMutation(using: appState)
            if conversation.leaveRequestPending || isLeaveAlreadyRequested(error) {
                conversation.markLeaveRequested()
                onGroupChanged(conversation.group)
                Haptics.warning()
                appState.present(.warning(L10n.string("Leaving group…")))
                dismiss()
                onGroupLeft(conversation.group.groupIdHex)
                return
            }
            handleActionError(error, title: L10n.string("Couldn't leave group"), using: appState)
        }
    }

    func endGroup(using appState: AppState) async {
        pendingConfirmation = nil
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        guard GroupManagementPresentation.canEndGroup(state: conversation.managementState) else {
            actionError = GroupManagementPresentation.disbandBlockerMessage(
                state: conversation.managementState
            ) ?? L10n.string("This group can't be ended right now.")
            return
        }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }

        let groupIdHex = conversation.group.groupIdHex
        do {
            var state = conversation.managementState
            if state?.canEnableDisbanding == true {
                appState.present(.warning(
                    L10n.string("Preparing to end group…"),
                    message: L10n.string("Publishing group update.")
                ))
                let result: GroupMutationResultFfi
#if DEBUG
                if let enableGroupDisbandingForTesting {
                    result = try await enableGroupDisbandingForTesting(accountRef, groupIdHex)
                } else {
                    let client = try appState.currentMarmotClient()
                    result = try await client.enableGroupDisbanding(
                        accountRef: accountRef,
                        groupIdHex: groupIdHex
                    )
                }
#else
                let client = try appState.currentMarmotClient()
                result = try await client.enableGroupDisbanding(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
#endif
                conversation.applyGroupMutation(result)
                state = result.managementState
                onGroupChanged(conversation.group)
            }

            guard state?.canDisband == true else {
                actionError = GroupManagementPresentation.disbandBlockerMessage(state: state)
                    ?? L10n.string("This group can't be ended right now.")
                return
            }

            appState.present(.warning(
                L10n.string("Ending group…"),
                message: L10n.string("Removing everyone and publishing the final group update.")
            ))
            let request: DisbandRequestFfi
#if DEBUG
            if let disbandGroupForTesting {
                request = try await disbandGroupForTesting(accountRef, groupIdHex)
            } else {
                let client = try appState.currentMarmotClient()
                request = try await client.disbandGroup(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            }
#else
            let client = try appState.currentMarmotClient()
            request = try await client.disbandGroup(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
#endif
            conversation.markDisbandRequested(request)
            onGroupChanged(conversation.group)
            await refreshVisibleDebugState(using: appState)
            Haptics.warning()
            appState.present(.warning(
                L10n.string("Ending group…"),
                message: L10n.string("Messaging is disabled while the request is processed.")
            ))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't end group"), using: appState)
        }
    }

    func acknowledgeDisbandFailure(using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef,
              case .some(.failed(_, _)) =
                conversation.group.disbandRequest ?? conversation.managementState?.disbandRequest
        else { return }
        guard !membershipActionInFlight else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }

        do {
            let acknowledged: Bool
#if DEBUG
            if let acknowledgeDisbandFailureForTesting {
                acknowledged = try await acknowledgeDisbandFailureForTesting(
                    accountRef,
                    conversation.group.groupIdHex
                )
            } else {
                let client = try appState.currentMarmotClient()
                acknowledged = try await client.acknowledgeDisbandFailure(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex
                )
            }
#else
            let client = try appState.currentMarmotClient()
            acknowledged = try await client.acknowledgeDisbandFailure(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex
            )
#endif
            if acknowledged {
                conversation.clearDisbandFailure()
                onGroupChanged(conversation.group)
            }
            await refreshGroupManagementAndNotify()
        } catch {
            handleActionError(
                error,
                title: L10n.string("Couldn't dismiss group status"),
                using: appState
            )
        }
    }

    func deleteLocal(using appState: AppState, dismiss: () -> Void) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        // Only a leave the group has not committed yet blocks the local delete.
        // Once membership has ended the departure is already on the wire, and
        // the pending flag may never clear.
        guard conversation.departureStatus != .leaving else {
            actionError = GroupManagementPresentation.leavingGroupComposerMessage
            return
        }
        guard !conversation.canSendMessages else {
            actionError = L10n.string("Leave this group before deleting the local copy.")
            return
        }
        guard !membershipActionInFlight else { return }
        let groupIdHex = conversation.group.groupIdHex
        membershipActionInFlight = true
        var preparedForRemoval = false
        defer { membershipActionInFlight = false }
        do {
            conversation.prepareForLocalGroupRemoval()
            preparedForRemoval = true
#if DEBUG
            if let deleteGroupLocalForTesting {
                _ = try await deleteGroupLocalForTesting(accountRef, groupIdHex)
            } else {
                let client = try appState.currentMarmotClient()
                _ = try await client.deleteGroupLocal(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                )
            }
#else
            let client = try appState.currentMarmotClient()
            _ = try await client.deleteGroupLocal(
                accountRef: accountRef,
                groupIdHex: groupIdHex
            )
#endif
            Haptics.warning()
            dismiss()
            onGroupDeleted(groupIdHex)
        } catch {
            if preparedForRemoval {
                await conversation.start()
            }
            handleActionError(error, title: L10n.string("Couldn't delete chat"), using: appState)
        }
    }

    private func handleActionError(_ error: Error, title: String, using appState: AppState) {
        let message = actionMessage(for: error)
        Haptics.error()
        actionError = message
        appState.present(.error(title, message: message))
    }

    private func actionMessage(for error: Error) -> String {
        guard let marmotError = error as? MarmotKitError else {
            return error.localizedDescription
        }
        switch marmotError {
        case .LeaveAlreadyRequested:
            return GroupManagementPresentation.leavingGroupComposerMessage
        case .NotGroupAdmin:
            return L10n.string("Only admins can manage group members.")
        case .AdminCannotSelfRemove:
            return L10n.string("Step down as admin before leaving the group.")
        case .WouldRemoveLastAdmin:
            return L10n.string("Make another member an admin before removing the last admin.")
        case .DisbandingUnsupportedMembers(_, let memberIds):
            return L10n.plural(
                "%lld members must update White Noise before you can end this group.",
                Int64(memberIds.count)
            )
        case .DisbandingNotEnabled:
            return L10n.string("Group ending isn't ready yet. Try again.")
        case .GroupDisbanding:
            return GroupManagementPresentation.disbandingComposerMessage
        case .MemberNotInGroup:
            return L10n.string("That member is no longer in this group.")
        case .AlreadyAdmin:
            return L10n.string("That member is already an admin.")
        case .NotAdmin:
            return L10n.string("That member is not an admin.")
        case .MissingKeyPackage(let account):
            return L10n.formatted(
                "%@ hasn't published a compatible key package yet.",
                IdentityFormatter.short(account)
            )
        default:
            return marmotError.localizedDescription
        }
    }

    private func isLeaveAlreadyRequested(_ error: Error) -> Bool {
        guard let error = error as? MarmotKitError else { return false }
        if case .LeaveAlreadyRequested = error { return true }
        return false
    }

    private func publishMessage(for summary: SendSummaryFfi) -> String {
        switch summary.acceptDisposition {
        case .acceptedPending:
            return L10n.string("Saved and waiting to send.")
        case .completionUnknown:
            return L10n.string("Saved; delivery confirmation is pending.")
        case .published:
            break
        }
        guard summary.published > 0 else { return L10n.string("Saved locally.") }
        return L10n.plural("Published %lld updates.", Int64(clamping: summary.published))
    }

    private func refreshAfterFailedMutation(using appState: AppState) async {
        guard let conversation else { return }
        _ = await conversation.refreshGroupManagement()
        await refreshVisibleDebugState(using: appState)
    }

    func refreshGroupManagementAndNotify() async {
        guard let conversation else { return }
        if await conversation.refreshGroupManagement() {
            onGroupChanged(conversation.group)
        }
    }

    func exportConversationTranscript(using appState: AppState) async {
        guard let conversation,
              !isExportingTranscript,
              let accountRef = appState.activeAccountRef
        else { return }

        isExportingTranscript = true
        defer { isExportingTranscript = false }

        cleanupTranscriptExportFile()

        do {
            let client = try appState.currentMarmotClient()
            let url = try await client.exportConversationTranscript(
                accountRef: accountRef,
                group: conversation.group
            )
            transcriptExportURL = url
            showTranscriptShareSheet = true
        } catch is CancellationError {
            // The export task can be cancelled while the detached worker is paging history.
        } catch {
            transcriptExportError = error.localizedDescription
        }
    }

    func cleanupTranscriptExportFile() {
        if let transcriptExportURL {
            try? FileManager.default.removeItem(at: transcriptExportURL)
        }
        transcriptExportURL = nil
    }

    func refreshVisibleDebugState(using appState: AppState) async {
        guard appState.developerMode else {
            mlsState = nil
            pushDebugInfo = nil
            pushDebugError = nil
            maintenanceStatus = nil
            maintenanceStatusError = nil
            return
        }
        guard let conversation, let accountRef = appState.activeAccountRef,
              let client = try? appState.currentMarmotClient() else { return }
        async let mlsResult = client.groupMlsState(
            accountRef: accountRef,
            groupIdHex: conversation.group.groupIdHex
        )
        async let pushResult = client.groupPushDebugInfo(
            accountRef: accountRef,
            groupIdHex: conversation.group.groupIdHex
        )
        async let maintenanceResult = client.groupMaintenanceStatus(
            accountRef: accountRef,
            groupIdHex: conversation.group.groupIdHex
        )
        mlsState = try? await mlsResult
        do {
            pushDebugInfo = try await pushResult
            pushDebugError = nil
        } catch {
            pushDebugInfo = nil
            pushDebugError = error.localizedDescription
        }
        do {
            maintenanceStatus = try await maintenanceResult
            maintenanceStatusError = nil
        } catch {
            maintenanceStatus = nil
            maintenanceStatusError = error.localizedDescription
        }
    }
}

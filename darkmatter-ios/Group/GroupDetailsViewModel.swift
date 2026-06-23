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
    var showRename = false
    var showGroupImageEditor = false
    var renameDraft = ""
    var actionError: String?
    var mlsState: AppGroupMlsStateFfi?
    var pushDebugInfo: GroupPushDebugInfoFfi?
    var pushDebugError: String?
    var pendingConfirmation: GroupDetailsConfirmation?
    var membershipActionInFlight = false
    var showRelays = false
    var actionHelp: GroupActionHelp?
    var isExportingTranscript = false
    var transcriptExportURL: URL?
    var showTranscriptShareSheet = false
    var transcriptExportError: String?

    // Bound by the view at the top of `body` (both @ObservationIgnored, so the
    // assignment never triggers a re-render). `conversation` is therefore set
    // before any method runs.
    @ObservationIgnored var conversation: ConversationViewModel?
    @ObservationIgnored var onGroupChanged: (AppGroupRecordFfi) -> Void = { _ in }

    func invite(refs: [String], using appState: AppState) async throws {
        guard let conversation, let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(L10n.string("Inviting members…"), message: L10n.string("Publishing group update.")))
            let result = try await appState.marmot.inviteMembersDetailed(
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
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning(L10n.string("Removing member…"), message: L10n.string("Publishing group update.")))
            let result = try await appState.marmot.removeMembersDetailed(
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
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        conversation.applyOptimisticAdminStatus(memberIdHex: member.memberIdHex, isAdmin: admin)
        appState.present(.warning(
            admin ? L10n.string("Making admin…") : L10n.string("Removing admin…"),
            message: L10n.string("Publishing group update.")
        ))
        do {
            let result: GroupMutationResultFfi
            if admin {
                result = try await appState.marmot.promoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            } else {
                result = try await appState.marmot.demoteAdminDetailed(
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
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        if let myAccountId = conversation.managementState?.myAccountIdHex {
            conversation.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
        }
        appState.present(.warning(L10n.string("Stepping down…"), message: L10n.string("Publishing group update.")))
        do {
            let result = try await appState.marmot.selfDemoteAdminDetailed(
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

    func rename(using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef,
              let name = GroupDetailsView.validatedGroupName(renameDraft) else { return }
        do {
            appState.present(.warning(L10n.string("Updating group name…"), message: L10n.string("Publishing group update.")))
            let summary = try await appState.marmot.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                name: name,
                description: nil
            )
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.success(L10n.string("Group name updated"), message: publishMessage(for: summary)))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't rename group"), message: error.localizedDescription))
        }
    }

    func updateGroupImage(url: String?, using appState: AppState) async throws {
        guard let conversation, let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        let normalizedURL: String?
        if let url {
            guard let sanitized = GroupImageURLSheet.validatedImageURL(url) else {
                throw GroupDetailsActionError.invalidImageURL
            }
            normalizedURL = sanitized.absoluteString
        } else {
            normalizedURL = nil
        }

        do {
            appState.present(.warning(L10n.string("Updating group image…"), message: L10n.string("Publishing group update.")))
            let summary = try await appState.marmot.updateGroupAvatarUrl(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                url: normalizedURL,
                dim: nil,
                thumbhash: nil
            )
            await refreshGroupManagementAndNotify()
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(.success(
                normalizedURL == nil ? L10n.string("Group image removed") : L10n.string("Group image updated"),
                message: publishMessage(for: summary)
            ))
        } catch {
            await refreshAfterFailedMutation(using: appState)
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't update group image"), message: error.localizedDescription))
            throw error
        }
    }

    func setArchived(_ archived: Bool, using appState: AppState) async {
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        do {
            let record = try await appState.marmot.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex,
                archived: archived
            )
            conversation.applyGroupRecord(record)
            onGroupChanged(record)
            await refreshVisibleDebugState(using: appState)
            Haptics.success()
            appState.present(archived ? .warning(L10n.string("Group archived")) : .success(L10n.string("Group unarchived")))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't update archive"), message: error.localizedDescription))
        }
    }

    func leave(using appState: AppState, dismiss: DismissAction) async {
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
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: conversation.managementState) {
                if let myAccountId = conversation.managementState?.myAccountIdHex {
                    conversation.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
                }
                appState.present(.warning(L10n.string("Stepping down before leaving…"), message: L10n.string("Publishing group update.")))
                let result = try await appState.marmot.selfDemoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: conversation.group.groupIdHex
                )
                conversation.applyGroupMutation(result)
                await refreshVisibleDebugState(using: appState)
            }
            appState.present(.warning(L10n.string("Leaving group…"), message: L10n.string("Publishing group update.")))
            _ = try await appState.marmot.leaveGroup(
                accountRef: accountRef,
                groupIdHex: conversation.group.groupIdHex
            )
            Haptics.warning()
            appState.present(.warning(L10n.string("You left the group")))
            dismiss()
        } catch {
            await refreshAfterFailedMutation(using: appState)
            handleActionError(error, title: L10n.string("Couldn't leave group"), using: appState)
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
        case .NotGroupAdmin:
            return L10n.string("Only admins can manage group members.")
        case .AdminCannotSelfRemove:
            return L10n.string("Step down as admin before leaving the group.")
        case .WouldRemoveLastAdmin:
            return L10n.string("Make another member an admin before removing the last admin.")
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

    private func publishMessage(for summary: SendSummaryFfi) -> String {
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
            return
        }
        guard let conversation, let accountRef = appState.activeAccountRef else { return }
        async let mlsResult = appState.marmot.groupMlsState(
            accountRef: accountRef,
            groupIdHex: conversation.group.groupIdHex
        )
        async let pushResult = appState.marmot.groupPushDebugInfo(
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
    }
}

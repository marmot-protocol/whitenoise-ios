import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct QuarantinedGroupsViewModelTests {
    @Test func reloadSortsGroupsAndUsesActiveAccount() async {
        let model = QuarantinedGroupsViewModel()
        let dataSource = QuarantinedGroupsDataSourceStub(groups: [
            group("bb", reason: .memberValidationFailed),
            group("aa", reason: .openMlsLoadFailed),
        ])

        await model.reload(using: dataSource)

        #expect(dataSource.loadRequests == ["account-a"])
        #expect(model.groups.map(\.groupIdHex) == ["aa", "bb"])
        #expect(model.loadError == nil)
    }

    @Test func successfulRetryRemovesGroupAndReloadsAuthoritativeList() async {
        let target = group("aa", reason: .openMlsLoadFailed)
        let model = QuarantinedGroupsViewModel()
        let dataSource = QuarantinedGroupsDataSourceStub(groups: [target])
        await model.reload(using: dataSource)
        dataSource.groups = []
        dataSource.retryResult = true

        await model.retry(target, using: dataSource)

        #expect(dataSource.retryRequests.count == 1)
        #expect(dataSource.retryRequests.first?.0 == "account-a")
        #expect(dataSource.retryRequests.first?.1 == "aa")
        #expect(dataSource.loadRequests == ["account-a", "account-a"])
        #expect(model.groups.isEmpty)
        #expect(model.retryStatusByGroupId["aa"] == nil)
        #expect(dataSource.presentedToasts.count == 1)
    }

    @Test func unsuccessfulRetryKeepsGroupAndRefreshesReason() async {
        let target = group("aa", reason: .openMlsLoadFailed)
        let model = QuarantinedGroupsViewModel()
        let dataSource = QuarantinedGroupsDataSourceStub(groups: [target])
        await model.reload(using: dataSource)
        dataSource.groups = [group("aa", reason: .pendingCommitRecoveryFailed)]
        dataSource.retryResult = false

        await model.retry(target, using: dataSource)

        #expect(model.groups.map(\.reason) == [.pendingCommitRecoveryFailed])
        #expect(model.retryStatusByGroupId["aa"] == .stillQuarantined)
        #expect(!model.retryingGroupIds.contains("aa"))
    }

    @Test func retryResultFromPreviousAccountIsIgnored() async {
        let target = group("aa", reason: .openMlsLoadFailed)
        let model = QuarantinedGroupsViewModel()
        let dataSource = QuarantinedGroupsDataSourceStub(groups: [target])
        await model.reload(using: dataSource)
        dataSource.retryResult = true
        dataSource.activeAccountRefAfterRetry = "account-b"

        await model.retry(target, using: dataSource)

        #expect(model.groups == [target])
        #expect(dataSource.presentedToasts.isEmpty)
        #expect(model.retryingGroupIds.isEmpty)
    }

    @Test func presentationExplainsMissingOpenMlsStateWithoutPromisingRepair() {
        let presentation = QuarantinedGroupPresentation.reason(.openMlsGroupMissing)

        #expect(presentation.title == "OpenMLS group missing")
        #expect(presentation.guidance.contains("only helps if that state becomes available"))
    }

    @Test func onlyAFailedRewindRestoreWithholdsRetry() {
        let reasons: [AppGroupHydrationQuarantineReasonFfi] = [
            .openMlsLoadFailed, .openMlsGroupMissing, .memberValidationFailed,
            .groupRecordLoadFailed, .pendingCommitRecoveryFailed, .rewindRestoreFailed,
        ]
        let withheld = reasons.filter { !QuarantinedGroupPresentation.reason($0).allowsRetry }
        #expect(withheld == [.rewindRestoreFailed])
    }

    private func group(
        _ groupIdHex: String,
        reason: AppGroupHydrationQuarantineReasonFfi
    ) -> AppQuarantinedGroupFfi {
        AppQuarantinedGroupFfi(groupIdHex: groupIdHex, reason: reason)
    }
}

@MainActor
private final class QuarantinedGroupsDataSourceStub: QuarantinedGroupsDataSource {
    var activeAccountRef: String? = "account-a"
    var groups: [AppQuarantinedGroupFfi]
    var retryResult = false
    var activeAccountRefAfterRetry: String?
    var loadRequests: [String] = []
    var retryRequests: [(String, String)] = []
    var presentedToasts: [Toast] = []

    init(groups: [AppQuarantinedGroupFfi]) {
        self.groups = groups
    }

    func loadQuarantinedGroups(accountRef: String) async throws -> [AppQuarantinedGroupFfi] {
        loadRequests.append(accountRef)
        return groups
    }

    func retryHydrateQuarantinedGroup(accountRef: String, groupIdHex: String) async throws -> Bool {
        retryRequests.append((accountRef, groupIdHex))
        if let activeAccountRefAfterRetry {
            activeAccountRef = activeAccountRefAfterRetry
        }
        return retryResult
    }

    func present(_ toast: Toast) {
        presentedToasts.append(toast)
    }
}

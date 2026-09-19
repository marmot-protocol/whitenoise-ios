import Testing
@testable import whitenoise_ios

@MainActor
struct ChatListBulkLeaveStateTests {
    private let context = ChatLeaveOperation.Context(accountRef: "account", runtimeGeneration: 1)
    private let targets = ["a", "b", "c"].map {
        ChatListLeavePresentation.Target(groupIdHex: $0, title: $0)
    }

    @Test func preparationCapturesCountAndAdminDisclosureWithoutLeaving() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) {
            $0.groupIdHex == "b"
        }
        let confirmation = try #require(state.confirmation)
        #expect(confirmation.targets.count == 3)
        #expect(confirmation.requiresSelfDemotion)
        #expect(!state.isBusy)
        #expect(state.retainedIDs.isEmpty)
        state.cancelConfirmation()
        #expect(!state.approve(confirmation, isCurrent: true))
        let result = await state.runApproved(isCurrent: { true }) { _ in
            Issue.record("Cancellation must never leave a chat")
            return .left
        }
        #expect(result == nil)
    }

    @Test func failedEligibilityNeverOffersPartialConfirmation() async {
        struct Blocked: Error { }
        let state = ChatListBulkLeaveState()
        do {
            try await state.prepare(context: context, targets: targets, isCurrent: { true }) { target in
                if target.groupIdHex == "b" { throw Blocked() }
                return false
            }
            Issue.record("The blocked chat must fail preparation")
        } catch { }
        #expect(state.confirmation == nil)
        #expect(!state.isBusy)
        #expect(state.processingID == nil)
        #expect(state.retainedIDs.isEmpty)
    }

    @Test func contextChangeDuringPreparationDiscardsConfirmation() async throws {
        let state = ChatListBulkLeaveState()
        var isCurrent = true
        var calls = 0
        try await state.prepare(context: context, targets: targets, isCurrent: { isCurrent }) { _ in
            calls += 1
            isCurrent = false
            return false
        }
        #expect(calls == 1)
        #expect(state.confirmation == nil)
    }

    @Test func partialFailurePreservesTheWholeSelectionAndReportsOnlyFailures() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) { _ in false }
        let confirmation = try #require(state.confirmation)
        #expect(!state.approve(confirmation, isCurrent: false))
        #expect(state.approve(confirmation, isCurrent: true))
        #expect(!state.approve(confirmation, isCurrent: true))
        var calls: [String] = []
        let result = await state.runApproved(isCurrent: { true }) { target in
            calls.append(target.groupIdHex)
            return target.groupIdHex == "b" ? .failed : .left
        }
        #expect(calls == ["a", "b", "c"])
        #expect(result?.failedIDs == ["b"])
        #expect(state.retainedIDs == ["a", "b", "c"])
        #expect(!state.isBusy)
        state.clearSelection()
        #expect(state.retainedIDs.isEmpty)
    }

    @Test func contextChangeStopsTheRemainingMutations() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) { _ in false }
        #expect(state.approve(try #require(state.confirmation), isCurrent: true))
        var isCurrent = true
        var calls = 0
        let result = await state.runApproved(isCurrent: { isCurrent }) { _ in
            calls += 1
            isCurrent = false
            return .left
        }
        #expect(calls == 1)
        #expect(result == nil)
        #expect(!state.isBusy)
    }

    @Test func successfulBatchRemainsSelectedForLocalDeletion() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) { _ in false }
        #expect(state.approve(try #require(state.confirmation), isCurrent: true))
        let result = await state.runApproved(isCurrent: { true }) { _ in .left }
        #expect(result?.failedIDs.isEmpty == true)
        #expect(state.retainedIDs == ["a", "b", "c"])
        #expect(ChatListSelection.canDeleteLocally([.deleteLocally, .deleteLocally, .deleteLocally]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, .leave, .deleteLocally]))
        #expect(!ChatListSelection.canDeleteLocally([.deleteLocally, nil]))
    }

    @Test func pendingRequestsAreRetainedWithoutReportingFailure() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) { _ in false }
        #expect(state.approve(try #require(state.confirmation), isCurrent: true))
        let result = await state.runApproved(isCurrent: { true }) { target in
            switch target.groupIdHex {
            case "a": .left
            case "b": .pending
            default: .failed
            }
        }
        #expect(result?.pendingIDs == ["b"])
        #expect(result?.failedIDs == ["c"])
        #expect(state.retainedIDs == ["a", "b", "c"])
    }

    @Test func cancelledOperationStopsTheBatch() async throws {
        let state = ChatListBulkLeaveState()
        try await state.prepare(context: context, targets: targets, isCurrent: { true }) { _ in false }
        #expect(state.approve(try #require(state.confirmation), isCurrent: true))
        var calls = 0
        let result = await state.runApproved(isCurrent: { true }) { _ in
            calls += 1
            return .cancelled
        }
        #expect(result == nil)
        #expect(calls == 1)
        #expect(!state.isBusy)
    }

}

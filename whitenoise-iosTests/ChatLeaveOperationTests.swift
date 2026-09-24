import Testing
@testable import whitenoise_ios

@MainActor
struct ChatLeaveOperationTests {
    private struct PublishFailure: Error {}

    @Test func pendingRequestDoesNotLeaveAgainOrBecomeEndedMembership() async {
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            .init(leaveRequestPending: true)
        }, selfDemote: {
            Issue.record("A pending leave must not demote again")
        }, leave: {
            Issue.record("A pending leave must not publish again")
        })
        #expect(result == .pending)
    }

    @Test func endedMembershipTakesPrecedenceOverOutstandingRequest() async {
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            .init(membershipEnded: true, leaveRequestPending: true)
        }, selfDemote: {
            Issue.record("An ended membership must not demote")
        }, leave: {
            Issue.record("An ended membership must not leave again")
        })
        #expect(result == .left)
    }

    @Test func lastAdminIsBlockedWithoutMutating() async {
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            .init(canLeave: false, requiresSelfDemotion: true, blockedMessage: "Assign another admin")
        }, selfDemote: {
            Issue.record("A blocked action must not demote")
        }, leave: {
            Issue.record("A blocked action must not leave")
        })
        #expect(result == .blocked("Assign another admin"))
    }

    @Test func successfulAdminLeaveDemotesBeforePublishing() async {
        var calls: [String] = []
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            .init(canLeave: true, requiresSelfDemotion: true)
        }, selfDemote: {
            calls.append("demote")
        }, leave: {
            calls.append("leave")
        })
        #expect(calls == ["demote", "leave"])
        #expect(result == .left)
    }

    @Test(arguments: [false, true])
    func failedPublishUsesDurableDepartureState(membershipEnded: Bool) async {
        var reads = 0
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            reads += 1
            return reads == 1
                ? .init(canLeave: true)
                : .init(membershipEnded: membershipEnded, leaveRequestPending: true)
        }, selfDemote: {
            Issue.record("An ordinary member does not demote")
        }, leave: {
            throw PublishFailure()
        })
        #expect(reads == 2)
        #expect(result == (membershipEnded ? .left : .pending))
    }

    @Test func failedPublishWithoutDurableRequestIsFailure() async {
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            .init(canLeave: true)
        }, selfDemote: {}, leave: { throw PublishFailure() })
        #expect(result == .failed)
    }

    @Test func unreadableRecoveryDoesNotInventSuccess() async {
        var reads = 0
        let result = await ChatLeaveOperation.perform(isCurrent: { true }, readState: {
            reads += 1
            if reads == 2 { throw PublishFailure() }
            return .init(canLeave: true)
        }, selfDemote: {}, leave: { throw PublishFailure() })
        #expect(result == .failed)
    }

    @Test func accountChangeDuringReadPreventsMutation() async {
        var isCurrent = true
        let result = await ChatLeaveOperation.perform(isCurrent: { isCurrent }, readState: {
            isCurrent = false
            return .init(canLeave: true)
        }, selfDemote: { Issue.record("Stale operation") }, leave: { Issue.record("Stale operation") })
        #expect(result == .cancelled)
    }

    @Test func accountChangeDuringDemotionPreventsLeave() async {
        var isCurrent = true
        let result = await ChatLeaveOperation.perform(isCurrent: { isCurrent }, readState: {
            .init(canLeave: true, requiresSelfDemotion: true)
        }, selfDemote: {
            isCurrent = false
        }, leave: {
            Issue.record("Must not leave after context changes")
        })
        #expect(result == .cancelled)
    }

    @Test func accountChangeDuringPublishDiscardsCompletion() async {
        var isCurrent = true
        let result = await ChatLeaveOperation.perform(isCurrent: { isCurrent }, readState: {
            .init(canLeave: true)
        }, selfDemote: {}, leave: { isCurrent = false })
        #expect(result == .cancelled)
    }

    @Test func accountChangeDuringRecoveryDiscardsResult() async {
        var isCurrent = true
        var reads = 0
        let result = await ChatLeaveOperation.perform(isCurrent: { isCurrent }, readState: {
            reads += 1
            if reads == 2 {
                isCurrent = false
                return .init(membershipEnded: true)
            }
            return .init(canLeave: true)
        }, selfDemote: {}, leave: { throw PublishFailure() })
        #expect(result == .cancelled)
    }
}

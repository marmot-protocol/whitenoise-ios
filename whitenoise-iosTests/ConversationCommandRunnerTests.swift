import Testing
import MarmotKit
@testable import whitenoise_ios

@MainActor
struct ConversationCommandRunnerTests {
    @Test func timedOutPageWaitsForSameHandleUpdateAndRecognizesEarlyCompletion() {
        var admission = ConversationPageAdmission()
        let attempted = ConversationWindowRevisionFfi(generation: "handle", sequence: 10)
        admission.awaitCompletion(of: attempted, installed: attempted)
        #expect(admission.unresolvedRevision != nil)
        admission.observe(.init(generation: "other", sequence: 11))
        #expect(admission.unresolvedRevision != nil)
        admission.observe(attempted)
        #expect(admission.unresolvedRevision != nil)
        admission.observe(.init(generation: "handle", sequence: 11))
        #expect(admission.unresolvedRevision == nil)
        admission.awaitCompletion(of: attempted, installed: .init(generation: "handle", sequence: 11))
        #expect(admission.unresolvedRevision == nil)
    }

    @Test func staleCommandUsesConsumedRevision() async {
        var revision = ConversationWindowRevisionFfi(generation: "handle", sequence: 1)
        var attempts: [UInt64] = []
        let result = await ConversationCommandRunner.run(isCurrent: { true }, revision: { revision },
            waitForUpdate: { _ in revision.sequence += 1 }, execute: { current -> Int in
                attempts.append(current.sequence)
                if current.sequence == 1 { throw MarmotKitError.ConversationWindowStale }
                return 42
            })
        #expect(attempts == [1, 2])
        if case .applied(let value) = result { #expect(value == 42) }
        else { Issue.record("Expected applied command") }
    }

    @Test func continuousRacesAreBounded() async {
        var revision = ConversationWindowRevisionFfi(generation: "handle", sequence: 1)
        var attempts = 0
        let result: ConversationCommandResolution<Int> = await ConversationCommandRunner.run(
            isCurrent: { true }, revision: { revision }, waitForUpdate: { _ in revision.sequence += 1 },
            execute: { _ in attempts += 1; throw MarmotKitError.ConversationWindowStale })
        #expect(attempts == 3)
        if case .rejected = result {} else { Issue.record("Expected explicit rejection") }
    }

    @Test(arguments: [MarmotKitError.ConversationWindowTimedOut, .ConversationWindowNotReady])
    func admittedCommandIsNeverReplayed(_ error: MarmotKitError) async {
        var attempts = 0
        let result: ConversationCommandResolution<Int> = await ConversationCommandRunner.run(
            isCurrent: { true }, revision: { .init(generation: "handle", sequence: 1) },
            waitForUpdate: { _ in Issue.record("Must not replay admitted command") },
            execute: { _ in attempts += 1; throw error })
        #expect(attempts == 1)
        if case .awaitingProjection = result {} else { Issue.record("Expected uncertain admission") }
    }

    @Test func retiredHandleCannotApplyLateResult() async {
        var current = true
        let result = await ConversationCommandRunner.run(isCurrent: { current },
            revision: { .init(generation: "old", sequence: 1) }, waitForUpdate: { _ in },
            execute: { _ in current = false; return 42 })
        if case .superseded = result {} else { Issue.record("Retired handle result escaped") }
    }

    @Test func supersededAnchorNeverRuns() async {
        let result: ConversationCommandResolution<Int> = await ConversationCommandRunner.run(isCurrent: { false },
            revision: { .init(generation: "handle", sequence: 1) }, waitForUpdate: { _ in },
            execute: { _ in Issue.record("Obsolete anchor executed"); return 42 })
        if case .superseded = result {} else { Issue.record("Expected superseded intent") }
    }
}

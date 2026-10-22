import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct GroupChangeAdvisoryTests {
    private let group = String(repeating: "a", count: 64)

    @Test func mapsOnlyTheTwoAdvisoryRefusals() {
        #expect(GroupChangeAdvisory(error: MarmotKitError.GroupCatchingUp(groupIdHex: group)) == .catchingUp)
        #expect(GroupChangeAdvisory(error: MarmotKitError.GroupCommitUndelivered(groupIdHex: group)) == .commitUndelivered)
        #expect(GroupChangeAdvisory(error: MarmotKitError.NotGroupAdmin(groupIdHex: group)) == nil)
        #expect(GroupChangeAdvisory(error: CancellationError()) == nil)
    }

    @Test func invitesGetTheStrongestCatchingUpWarning() {
        let invite = GroupChangeAdvisory.catchingUp.message(isInvite: true)
        let change = GroupChangeAdvisory.catchingUp.message(isInvite: false)
        #expect(invite != change)
        #expect(invite.contains("invitation"))
        #expect(change.contains("split"))
    }

    @Test func acceptedRefusalIsAcknowledgedThenRetriedOnce() async throws {
        var attempts = 0
        var asked: [GroupChangeAdvisory] = []
        var acknowledged: [GroupChangeAdvisory] = []
        let result = try await GroupChangeAdvisoryRetry.perform({
            attempts += 1
            if attempts == 1 { throw MarmotKitError.GroupCatchingUp(groupIdHex: group) }
            return "published"
        }, consent: { asked.append($0); return true }, acknowledge: { acknowledged.append($0) })

        #expect(result == "published")
        #expect(attempts == 2)
        #expect(asked == [.catchingUp])
        #expect(acknowledged == [.catchingUp])
    }

    @Test func aChangeCanNeedBothAcknowledgementsInTurn() async throws {
        var refusals: [MarmotKitError] = [
            .GroupCatchingUp(groupIdHex: group), .GroupCommitUndelivered(groupIdHex: group)
        ]
        var acknowledged: [GroupChangeAdvisory] = []
        try await GroupChangeAdvisoryRetry.perform({
            if !refusals.isEmpty { throw refusals.removeFirst() }
        }, consent: { _ in true }, acknowledge: { acknowledged.append($0) })

        #expect(acknowledged == [.catchingUp, .commitUndelivered])
    }

    @Test func waitingThrowsDeclinedWithoutAcknowledging() async {
        var attempts = 0
        var acknowledged = false
        await #expect(throws: GroupChangeAdvisoryDeclined(advisory: .commitUndelivered)) {
            try await GroupChangeAdvisoryRetry.perform({
                attempts += 1
                throw MarmotKitError.GroupCommitUndelivered(groupIdHex: group)
            }, consent: { _ in false }, acknowledge: { _ in acknowledged = true })
        }
        #expect(attempts == 1)
        #expect(!acknowledged)
    }

    @Test func aRefusalThatRecursAfterItsAcknowledgementIsNotAskedAgain() async {
        var asked = 0
        await #expect(throws: MarmotKitError.GroupCatchingUp(groupIdHex: group)) {
            try await GroupChangeAdvisoryRetry.perform({
                throw MarmotKitError.GroupCatchingUp(groupIdHex: group)
            }, consent: { _ in asked += 1; return true }, acknowledge: { _ in })
        }
        #expect(asked == 1)
    }

    @Test func otherFailuresPassThroughWithoutAsking() async {
        var asked = false
        await #expect(throws: MarmotKitError.NotGroupAdmin(groupIdHex: group)) {
            try await GroupChangeAdvisoryRetry.perform({
                throw MarmotKitError.NotGroupAdmin(groupIdHex: group)
            }, consent: { _ in asked = true; return true }, acknowledge: { _ in })
        }
        #expect(!asked)
    }

    @Test func declinedChangeExplainsThatNothingChanged() {
        let error: Error = GroupChangeAdvisoryDeclined(advisory: .catchingUp)
        #expect(UserFacingError.message(for: error) == GroupChangeAdvisory.catchingUp.declinedMessage)
    }

    @Test func prompterAnswersTheShownPromptOnly() async throws {
        let prompter = GroupChangeAdvisoryPrompter()
        let answer = Task { await prompter.requestConsent(for: .catchingUp, isInvite: true) }
        let prompt = try await shownPrompt(prompter)
        #expect(prompt.advisory == .catchingUp)
        #expect(prompt.isInvite)

        prompter.resolve(id: UUID(), approved: false)
        #expect(prompter.prompt == prompt)

        prompter.resolve(id: prompt.id, approved: true)
        #expect(await answer.value)
        #expect(prompter.prompt == nil)
    }

    @Test func aNewerRequestDeclinesTheOlderOne() async throws {
        let prompter = GroupChangeAdvisoryPrompter()
        let first = Task { await prompter.requestConsent(for: .catchingUp, isInvite: false) }
        let firstPrompt = try await shownPrompt(prompter)
        let second = Task { await prompter.requestConsent(for: .commitUndelivered, isInvite: false) }
        #expect(await first.value == false)

        let secondPrompt = try await shownPrompt(prompter)
        #expect(secondPrompt.id != firstPrompt.id)
        prompter.cancelPending()
        #expect(await second.value == false)
    }

    @Test func cancellingTheWaitingChangeDeclines() async throws {
        let prompter = GroupChangeAdvisoryPrompter()
        let answer = Task { await prompter.requestConsent(for: .catchingUp, isInvite: false) }
        _ = try await shownPrompt(prompter)
        answer.cancel()
        #expect(await answer.value == false)
    }

    private func shownPrompt(_ prompter: GroupChangeAdvisoryPrompter) async throws -> GroupChangeAdvisoryPrompter.Prompt {
        for _ in 0..<1_000 {
            if let prompt = prompter.prompt { return prompt }
            await Task.yield()
        }
        throw CancellationError()
    }
}

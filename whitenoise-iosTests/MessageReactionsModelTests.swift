import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct MessageReactionsModelTests {
    private typealias Details = ConversationViewModel.ReactionDetails
    private typealias Presentation = ReactionDetailsPresentation

    private static let group = String(repeating: "c", count: 64)
    private static let target = String(repeating: "a", count: 64)
    private static let subject = MessageReactionsSubject(
        accountRef: "alice", groupIdHex: group, messageIdHex: target, runtimeGeneration: 1)

    private static func account(_ byte: Int) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private static let me = account(0x11)

    private static func reaction(_ sender: Int, _ emoji: String, at reactedAt: UInt64,
                                 id: String? = nil) -> TimelineUserReactionFfi {
        TimelineUserReactionFfi(
            reactionMessageIdHex: id ?? "\(sender)-\(emoji)-\(reactedAt)",
            targetMessageIdHex: target,
            sender: account(sender),
            emoji: emoji,
            reactedAt: reactedAt
        )
    }

    /// A conversation-window preview: `count` reactions, at most two named.
    private static func preview(_ emoji: String, count: Int, senders: [String], mine: Bool = false,
                                id: String? = nil) -> Details.EmojiGroup {
        Details.EmojiGroup(emoji: emoji, senders: senders, mine: mine, totalCount: count, reactionMessageIdHex: id)
    }

    // MARK: Complete details

    @Test func everyReactorIsListedWithoutAProjectedPreview() {
        let reactions = (1...5).map { Self.reaction($0, "👍", at: UInt64($0)) } + [
            Self.reaction(1, "🔥", at: 6),
            Self.reaction(6, "🔥", at: 7)
        ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.groups.map(\.emoji) == ["👍", "🔥"])
        #expect(details.groups.map(\.count) == [5, 2])
        #expect(details.groups[0].senders == (1...5).map(Self.account))
        #expect(details.totalReactionCount == 7)
        #expect(!details.isTruncated)
        // One sender's different emoji stay separate entries.
        #expect(details.users(filteredBy: nil).first { $0.sender == Self.account(1) }?.emojis == ["👍", "🔥"])
    }

    @Test func theCompleteReadReplacesATruncatedPreview() {
        let projected = Details(
            groups: [Self.preview("👍", count: 4, senders: [Self.account(1), Self.account(2)], id: "window-id")],
            omittedKinds: 1,
            totalCount: 5
        )
        #expect(projected.isTruncated)
        let reactions = (1...4).map { Self.reaction($0, "👍", at: UInt64($0)) } + [Self.reaction(5, "🎉", at: 9)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(!details.isTruncated)
        #expect(details.groups.map(\.emoji) == ["👍", "🎉"])
        #expect(details.groups.map(\.count) == [4, 1])
        #expect(details.reactionMessageIdHex(for: "👍") == "window-id")
        #expect(details.reactionMessageIdHex(for: "🎉") == "5-🎉-9")
    }

    @Test func theEarliestReactionNamesAnEmojiOutsideThePreview() {
        let reactions = [
            Self.reaction(2, ":cat:", at: 20, id: "later"),
            Self.reaction(1, ":cat:", at: 10, id: "b-earliest"),
            Self.reaction(3, ":cat:", at: 10, id: "c-tie")
        ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.reactionMessageIdHex(for: ":cat:") == "b-earliest")
    }

    @Test func aPendingUnreactHidesTheViewerBeforeMDKCatchesUp() {
        // The window already applies the optimistic removal; the read is older.
        let projected = Details(groups: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        let reactions = [Self.reaction(0x11, "👍", at: 1), Self.reaction(2, "👍", at: 2)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.groups.map(\.count) == [1])
        #expect(details.groups[0].senders == [Self.account(2)])
        #expect(details.groups[0].mine == false)
    }

    @Test func aPendingReactShowsTheViewerBeforeMDKCatchesUp() {
        let projected = Details(groups: [
            Self.preview("👍", count: 1, senders: [Self.account(2)]),
            Self.preview("🔥", count: 1, senders: [Self.me], mine: true)
        ])
        let reactions = [Self.reaction(2, "👍", at: 2)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.groups.first { $0.emoji == "🔥" }?.senders == [Self.me])
        #expect(details.groups.first { $0.emoji == "🔥" }?.mine == true)
    }

    @Test func theWindowsViewerFlagWinsEvenWhenTheViewerIsOutsideTheTwoNamePreview() {
        let projected = Details(groups: [
            Self.preview("👍", count: 3, senders: [Self.account(2), Self.account(3)], mine: true)
        ])
        let reactions = [Self.reaction(2, "👍", at: 1), Self.reaction(3, "👍", at: 2), Self.reaction(0x11, "👍", at: 3)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.groups[0].senders == [Self.account(2), Self.account(3), Self.me])
        #expect(details.groups[0].mine)
    }

    @Test func anEmojiTheWindowDroppedIsNotResurrectedByAnOlderRead() {
        // Removing the only 🔥 drops it from a window that lists every kind.
        let projected = Details(groups: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        let reactions = [Self.reaction(2, "👍", at: 1), Self.reaction(0x11, "🔥", at: 2), Self.reaction(3, "😂", at: 3)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(details.groups.map(\.emoji) == ["👍"])
    }

    @Test func kindsTheWindowOmittedComeFromTheRead() {
        let projected = Details(
            groups: [Self.preview("👍", count: 1, senders: [Self.account(2)])],
            omittedKinds: 2,
            totalCount: 3
        )
        let reactions = [Self.reaction(2, "👍", at: 1), Self.reaction(0x11, "🔥", at: 2), Self.reaction(3, "😂", at: 3)]

        let details = Presentation.completeDetails(reactions, projected: projected, me: Self.me)

        #expect(Set(details.groups.map(\.emoji)) == ["👍", "🔥", "😂"])
        #expect(details.groups.first { $0.emoji == "🔥" }?.mine == true)
    }

    @Test func malformedAndDuplicateEntriesAreIgnored() {
        let reactions = [
            Self.reaction(2, "👍", at: 1),
            Self.reaction(2, "👍", at: 2),
            Self.reaction(3, "", at: 3),
            TimelineUserReactionFfi(reactionMessageIdHex: "x", targetMessageIdHex: Self.target,
                                    sender: "", emoji: "👍", reactedAt: 4)
        ]

        let details = Presentation.completeDetails(reactions, projected: nil, me: Self.me)

        #expect(details.groups.map(\.emoji) == ["👍"])
        #expect(details.groups[0].senders == [Self.account(2)])
    }

    // MARK: Sheet content

    @Test func aCompletePreviewShowsImmediatelyWhileTheFirstReadRuns() {
        let projected = Details(groups: [Self.preview("👍", count: 2, senders: [Self.account(2), Self.account(3)])])

        let content = Presentation.content(phase: .loading, hasLoaded: false, reactions: [],
                                           projected: projected, me: Self.me)

        #expect(content == .details(projected, refreshError: nil))
    }

    @Test func aTruncatedOrMissingPreviewWaitsForTheRead() {
        let truncated = Details(groups: [Self.preview("👍", count: 3, senders: [Self.account(2), Self.account(3)])])

        #expect(Presentation.content(phase: .loading, hasLoaded: false, reactions: [],
                                     projected: truncated, me: Self.me) == .loading)
        #expect(Presentation.content(phase: .idle, hasLoaded: false, reactions: [],
                                     projected: nil, me: Self.me) == .loading)
        #expect(Presentation.content(phase: .loading, hasLoaded: false, reactions: [],
                                     projected: Details(groups: []), me: Self.me) == .loading)
    }

    @Test func anEmptyReadIsAnEmptyStateNotAnError() {
        #expect(Presentation.content(phase: .loaded, hasLoaded: true, reactions: [],
                                     projected: nil, me: Self.me) == .empty)
    }

    @Test func aFailedFirstReadIsRetryableEvenWithACompletePreview() {
        let projected = Details(groups: [Self.preview("👍", count: 1, senders: [Self.account(2)])])

        #expect(Presentation.content(phase: .failed("Nope"), hasLoaded: false, reactions: [],
                                     projected: projected, me: Self.me) == .failed("Nope"))
        #expect(Presentation.content(phase: .failed("Nope"), hasLoaded: true, reactions: [],
                                     projected: nil, me: Self.me) == .failed("Nope"))
    }

    @Test func aFailedRefreshKeepsTheLastCompleteList() {
        let reactions = [Self.reaction(2, "👍", at: 1)]

        let content = Presentation.content(phase: .failed("Nope"), hasLoaded: true, reactions: reactions,
                                           projected: nil, me: Self.me)

        guard case .details(let details, let refreshError) = content else {
            Issue.record("Expected details, got \(content)")
            return
        }
        #expect(details.groups.map(\.emoji) == ["👍"])
        #expect(refreshError == "Nope")
    }

    @Test func theTappedEmojiSurvivesLoadingAndClearsOnlyWhenTheListLacksIt() {
        #expect(Presentation.selection("🔥", availableEmojis: nil) == "🔥")
        #expect(Presentation.selection("🔥", availableEmojis: ["👍", "🔥"]) == "🔥")
        #expect(Presentation.selection("🔥", availableEmojis: ["👍"]) == nil)
        #expect(Presentation.selection(nil, availableEmojis: ["👍"]) == nil)
        #expect(Presentation.availableEmojis(in: .loading) == nil)
        #expect(Presentation.availableEmojis(in: .empty) == nil)
        let details = Details(groups: [Self.preview("👍", count: 1, senders: [Self.account(2)])])
        #expect(Presentation.availableEmojis(in: .details(details, refreshError: nil)) == ["👍"])
    }

    // MARK: Loading

    @Test func loadsTheSubjectsCompleteList() async {
        let source = GatedMessageReactionsSource()
        source.respond(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        let model = MessageReactionsModel()

        await model.load(Self.subject, using: source)

        #expect(source.requests == [Self.subject])
        #expect(model.subject == Self.subject)
        #expect(model.reactions.map(\.sender) == [Self.account(2)])
        #expect(model.hasLoaded)
        #expect(model.phase == .loaded)
    }

    @Test func aReloadKeepsTheOldListUntilItCompletes() async throws {
        let source = GatedMessageReactionsSource()
        source.respond(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        let model = MessageReactionsModel()
        await model.load(Self.subject, using: source)

        source.gate(Self.subject)
        let reload = Task { await model.load(Self.subject, using: source) }
        try await source.waitUntilWaiting(Self.subject)
        #expect(model.phase == .loading)
        #expect(model.hasLoaded)
        #expect(model.reactions.map(\.sender) == [Self.account(2)])

        source.release(Self.subject, with: [Self.reaction(2, "👍", at: 1), Self.reaction(3, "👍", at: 2)])
        await reload.value

        #expect(model.reactions.map(\.sender) == [Self.account(2), Self.account(3)])
        #expect(model.phase == .loaded)
    }

    @Test func aNewRuntimeGenerationDiscardsTheOldListImmediately() async throws {
        let source = GatedMessageReactionsSource()
        source.respond(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        let model = MessageReactionsModel()
        await model.load(Self.subject, using: source)

        let restarted = MessageReactionsSubject(accountRef: "alice", groupIdHex: Self.group,
                                                messageIdHex: Self.target, runtimeGeneration: 2)
        source.gate(restarted)
        let reload = Task { await model.load(restarted, using: source) }
        try await source.waitUntilWaiting(restarted)

        #expect(model.subject == restarted)
        #expect(model.reactions.isEmpty)
        #expect(!model.hasLoaded)

        source.release(restarted, with: [])
        await reload.value
        #expect(model.hasLoaded)
        #expect(model.phase == .loaded)
    }

    @Test func aLateReadForAnotherAccountIsDiscarded() async throws {
        let source = GatedMessageReactionsSource()
        source.gate(Self.subject)
        let bob = MessageReactionsSubject(accountRef: "bob", groupIdHex: Self.group,
                                          messageIdHex: Self.target, runtimeGeneration: 1)
        source.respond(bob, with: [Self.reaction(3, "🔥", at: 1)])
        let model = MessageReactionsModel()

        let stale = Task { await model.load(Self.subject, using: source) }
        try await source.waitUntilWaiting(Self.subject)
        await model.load(bob, using: source)
        source.release(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        await stale.value

        #expect(model.subject == bob)
        #expect(model.reactions.map(\.emoji) == ["🔥"])
    }

    @Test func aSupersededReadOfTheSameMessageIsDiscarded() async throws {
        let source = GatedMessageReactionsSource()
        source.gate(Self.subject)
        let model = MessageReactionsModel()

        let older = Task { await model.load(Self.subject, using: source) }
        try await source.waitUntilWaiting(Self.subject)
        let olderContinuation = try #require(source.takeWaiter(Self.subject))

        let newer = Task { await model.load(Self.subject, using: source) }
        try await source.waitUntilWaiting(Self.subject)
        source.release(Self.subject, with: [Self.reaction(3, "🔥", at: 2)])
        await newer.value

        olderContinuation.resume(returning: [Self.reaction(2, "👍", at: 1)])
        await older.value

        #expect(model.reactions.map(\.emoji) == ["🔥"])
    }

    @Test func aReadFinishingAfterTheSheetClosedPublishesNothing() async throws {
        let source = GatedMessageReactionsSource()
        source.gate(Self.subject)
        let model = MessageReactionsModel()

        let load = Task { await model.load(Self.subject, using: source) }
        try await source.waitUntilWaiting(Self.subject)
        load.cancel()
        source.release(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        await load.value

        #expect(model.reactions.isEmpty)
        #expect(!model.hasLoaded)
        #expect(model.phase == .loading)
    }

    @Test func aFailedReadSurfacesItsMessageAndKeepsTheLastList() async {
        let source = GatedMessageReactionsSource()
        source.respond(Self.subject, with: [Self.reaction(2, "👍", at: 1)])
        let model = MessageReactionsModel()
        await model.load(Self.subject, using: source)

        source.fail(Self.subject, with: MarmotKitError.UnknownGroup(groupIdHex: "boom"))
        await model.load(Self.subject, using: source, errorMessage: { _ in "Couldn’t read" })

        #expect(model.phase == .failed("Couldn’t read"))
        #expect(model.hasLoaded)
        #expect(model.reactions.map(\.sender) == [Self.account(2)])
    }
}

/// Answers reads per subject, holding gated subjects until the test releases
/// them so a result can arrive after a newer load started.
private nonisolated final class GatedMessageReactionsSource: MessageReactionsDataSource {
    private struct State {
        var gated: Set<MessageReactionsSubject> = []
        var responses: [MessageReactionsSubject: [TimelineUserReactionFfi]] = [:]
        var failures: [MessageReactionsSubject: any Error] = [:]
        var waiters: [MessageReactionsSubject: CheckedContinuation<[TimelineUserReactionFfi], any Error>] = [:]
        var requests: [MessageReactionsSubject] = []
        var arrivals: [MessageReactionsSubject: [TestLatch]] = [:]
    }

    private let state = Mutex(State())

    var requests: [MessageReactionsSubject] { state.withLock { $0.requests } }

    func gate(_ subject: MessageReactionsSubject) {
        state.withLock { _ = $0.gated.insert(subject) }
    }

    func respond(_ subject: MessageReactionsSubject, with reactions: [TimelineUserReactionFfi]) {
        state.withLock {
            $0.responses[subject] = reactions
            $0.failures[subject] = nil
        }
    }

    func fail(_ subject: MessageReactionsSubject, with error: any Error) {
        state.withLock { $0.failures[subject] = error }
    }

    func takeWaiter(_ subject: MessageReactionsSubject) -> CheckedContinuation<[TimelineUserReactionFfi], any Error>? {
        state.withLock { $0.waiters.removeValue(forKey: subject) }
    }

    /// Resumes the held read and stops gating the subject.
    func release(_ subject: MessageReactionsSubject, with reactions: [TimelineUserReactionFfi]) {
        let waiter = state.withLock { state -> CheckedContinuation<[TimelineUserReactionFfi], any Error>? in
            state.gated.remove(subject)
            state.responses[subject] = reactions
            return state.waiters.removeValue(forKey: subject)
        }
        waiter?.resume(returning: reactions)
    }

    /// Returns once a gated read of `subject` is parked; the read signals it.
    func waitUntilWaiting(_ subject: MessageReactionsSubject) async throws {
        let arrival = TestLatch()
        let parked = state.withLock { state -> Bool in
            if state.waiters[subject] != nil { return true }
            state.arrivals[subject, default: []].append(arrival)
            return false
        }
        if !parked { try await arrival.wait() }
    }

    func messageReactions(for subject: MessageReactionsSubject) async throws -> [TimelineUserReactionFfi] {
        enum Immediate { case value([TimelineUserReactionFfi]), failure(any Error), gated }
        let immediate = state.withLock { state -> Immediate in
            state.requests.append(subject)
            if let failure = state.failures[subject] { return .failure(failure) }
            if state.gated.contains(subject) { return .gated }
            return .value(state.responses[subject] ?? [])
        }
        switch immediate {
        case .value(let reactions): return reactions
        case .failure(let error): throw error
        case .gated:
            return try await withCheckedThrowingContinuation { continuation in
                let arrivals = state.withLock { state -> [TestLatch] in
                    state.waiters[subject] = continuation
                    return state.arrivals.removeValue(forKey: subject) ?? []
                }
                for arrival in arrivals { arrival.signal() }
            }
        }
    }
}

import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@MainActor
struct PollVotesModelTests {
    private static let group = String(repeating: "c", count: 64)
    private static let pollA = String(repeating: "1", count: 64)
    private static let pollB = String(repeating: "2", count: 64)
    private static let subjectA = PollVotesSubject(accountRef: "alice", groupIdHex: group, pollEventId: pollA)
    private static let subjectB = PollVotesSubject(accountRef: "alice", groupIdHex: group, pollEventId: pollB)

    private static func voter(_ byte: Int) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private static func vote(_ byte: Int, _ options: [String] = ["0"], at votedAt: UInt64) -> PollVoteFfi {
        PollVoteFfi(voterAccountIdHex: voter(byte), optionIds: options, votedAt: votedAt)
    }

    private static let options = [
        PollOptionResultFfi(id: "0", label: "Thai", votes: 0),
        PollOptionResultFfi(id: "1", label: "Pizza", votes: 0),
        PollOptionResultFfi(id: "2", label: "Salad", votes: 0)
    ]

    // MARK: Paging and cursors

    @Test func loadsEveryPageWithTheLastVoteAsTheNextCursor() async {
        let source = ScriptedPollVotesSource(pages: [
            PollVotePageFfi(votes: [Self.vote(1, at: 10), Self.vote(2, at: 20)], hasMoreAfter: true),
            PollVotePageFfi(votes: [Self.vote(3, at: 20)], hasMoreAfter: true),
            PollVotePageFfi(votes: [Self.vote(4, at: 30)], hasMoreAfter: false)
        ])
        let model = PollVotesModel()

        await model.load(Self.subjectA, using: source)

        let calls = source.calls
        #expect(calls.map(\.cursor) == [
            nil,
            PollVotesCursor(votedAt: 20, voterAccountIdHex: Self.voter(2)),
            PollVotesCursor(votedAt: 20, voterAccountIdHex: Self.voter(3))
        ])
        #expect(calls.allSatisfy { $0.limit == PollVotesModel.pageLimit && $0.subject == Self.subjectA })
        #expect(PollVotesModel.pageLimit >= 1 && PollVotesModel.pageLimit <= 100)
        #expect(model.votes.map(\.voterAccountIdHex) == [1, 2, 3, 4].map(Self.voter))
        #expect(model.phase == .loaded)
        #expect(model.subject == Self.subjectA)
    }

    @Test func pagingStopsWhenMDKReportsNoMoreOrTheCursorCannotAdvance() {
        let last = Self.vote(2, at: 20)
        let cursor = PollVotesCursor(votedAt: 20, voterAccountIdHex: Self.voter(2))
        #expect(PollVotesPresentation.nextCursor(
            after: PollVotePageFfi(votes: [last], hasMoreAfter: false), previous: nil) == nil)
        #expect(PollVotesPresentation.nextCursor(
            after: PollVotePageFfi(votes: [], hasMoreAfter: true), previous: nil) == nil)
        #expect(PollVotesPresentation.nextCursor(
            after: PollVotePageFfi(votes: [last], hasMoreAfter: true), previous: cursor) == nil)
        #expect(PollVotesPresentation.nextCursor(
            after: PollVotePageFfi(votes: [last], hasMoreAfter: true), previous: nil) == cursor)
    }

    @Test func aCursorThatNeverAdvancesDoesNotLoopForever() async {
        let stuck = PollVotePageFfi(votes: [Self.vote(1, at: 10)], hasMoreAfter: true)
        let source = ScriptedPollVotesSource(pages: [stuck, stuck, stuck])
        let model = PollVotesModel()

        await model.load(Self.subjectA, using: source)

        #expect(source.calls.count == 2)
        #expect(model.phase == .loaded)
    }

    // MARK: Empty, deleted and failed

    @Test func anEmptyPageIsAnEmptyStateNotAnError() async {
        let source = ScriptedPollVotesSource(pages: [PollVotePageFfi(votes: [], hasMoreAfter: false)])
        let model = PollVotesModel()

        await model.load(Self.subjectA, using: source)

        let sections = PollVotesPresentation.sections(
            options: Self.options, votes: model.votes, blockedAccountIds: [], myAccountIdHex: nil)
        #expect(PollVotesPresentation.content(isPollAvailable: true, phase: model.phase, sections: sections) == .noVotes)
        #expect(PollVotesPresentation.content(isPollAvailable: false, phase: model.phase, sections: sections) == .unavailable)
    }

    @Test func aDeletedPollIsUnavailableEvenWithVotesStillOnScreen() {
        let sections = PollVotesPresentation.sections(
            options: Self.options, votes: [Self.vote(1, at: 1)], blockedAccountIds: [], myAccountIdHex: nil)
        #expect(PollVotesPresentation.content(isPollAvailable: false, phase: .loaded, sections: sections) == .unavailable)
    }

    @Test func aFailedReadSurfacesItsMessage() async {
        let source = ScriptedPollVotesSource(pages: [], failure: MarmotKitError.UnknownGroup(groupIdHex: "boom"))
        let model = PollVotesModel()

        await model.load(Self.subjectA, using: source, errorMessage: { _ in "Couldn’t read votes" })

        #expect(model.phase == .failed("Couldn’t read votes"))
        #expect(PollVotesPresentation.content(isPollAvailable: true, phase: model.phase, sections: []) == .failed("Couldn’t read votes"))
    }

    // MARK: Reload on reprojection

    @Test func aReloadReadsFromTheFirstPageAndKeepsTheOldListUntilItCompletes() async throws {
        let source = GatedPollVotesSource()
        source.respond(Self.subjectA, with: PollVotePageFfi(votes: [Self.vote(1, at: 10)], hasMoreAfter: false))
        let model = PollVotesModel()
        await model.load(Self.subjectA, using: source)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.voter(1)])

        source.gate(Self.subjectA)
        let reload = Task { await model.load(Self.subjectA, using: source) }
        try await source.waitUntilWaiting(Self.subjectA)
        #expect(model.phase == .loading)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.voter(1)])
        let options = Self.options
        let loadingSections = PollVotesPresentation.sections(
            options: options, votes: model.votes, blockedAccountIds: [], myAccountIdHex: nil)
        #expect(PollVotesPresentation.content(isPollAvailable: true, phase: model.phase, sections: loadingSections)
            == .votes(loadingSections))

        source.release(Self.subjectA, with: PollVotePageFfi(
            votes: [Self.vote(2, ["1"], at: 5), Self.vote(1, ["1"], at: 11)], hasMoreAfter: false))
        await reload.value

        #expect(source.cursors(for: Self.subjectA) == [nil, nil])
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.voter(2), Self.voter(1)])
        #expect(model.phase == .loaded)
    }

    @Test func pollRowReprojectionChangesTheRevisionOnlyWhenTheRowChanges() {
        let store = TimelineStore(appState: nil, groupIdHex: Self.group)
        let id = Self.pollA
        #expect(store.pollReprojectionRevision(for: id) == 0)

        store.applyTimelineRecord(pollRecord(id: id, votes: [1, 0]))
        let first = store.pollReprojectionRevision(for: id)
        #expect(first > 0)

        // A window reload re-applies the unchanged row.
        store.applyTimelineRecord(pollRecord(id: id, votes: [1, 0]))
        #expect(store.pollReprojectionRevision(for: id) == first)

        // A new vote changes the tally.
        store.applyTimelineRecord(pollRecord(id: id, votes: [1, 1]))
        let afterVote = store.pollReprojectionRevision(for: id)
        #expect(afterVote > first)

        // A live upsert counts even when the tally is unchanged (a re-vote).
        store.applyTimelineRecord(pollRecord(id: id, votes: [1, 1]), trigger: .messageEditedOrReprojected)
        let afterLive = store.pollReprojectionRevision(for: id)
        #expect(afterLive > afterVote)

        // Deletion reprojects the row without a tally.
        store.applyTimelineRecord(pollRecord(id: id, votes: nil, deleted: true))
        let afterDelete = store.pollReprojectionRevision(for: id)
        #expect(afterDelete > afterLive)

        store.removeTimelineRecord(messageIdHex: id)
        #expect(store.pollReprojectionRevision(for: id) > afterDelete)
    }

    @Test func nonPollRowsNeverGetARevision() {
        let store = TimelineStore(appState: nil, groupIdHex: Self.group)
        store.applyTimelineRecord(pollRecord(id: Self.pollA, votes: nil, kind: MessageSemantics.kindChat))
        #expect(store.pollReprojectionRevision(for: Self.pollA) == 0)
    }

    // MARK: Blocked voters

    @Test func blockedVotersStayListedAndAreMarkedRegardlessOfHexCase() {
        let me = Self.voter(1)
        let blocked = Self.voter(0xbb)
        let sections = PollVotesPresentation.sections(
            options: Self.options,
            votes: [
                PollVoteFfi(voterAccountIdHex: me.uppercased(), optionIds: ["0"], votedAt: 1),
                PollVoteFfi(voterAccountIdHex: blocked, optionIds: ["0", "1"], votedAt: 2),
                Self.vote(3, ["1"], at: 3)
            ],
            blockedAccountIds: [blocked.uppercased()],
            myAccountIdHex: me
        )

        #expect(sections.map(\.id) == ["0", "1", "2"])
        #expect(sections[0].voters.map(\.accountIdHex) == [me, blocked])
        #expect(sections[0].voters.map(\.isBlocked) == [false, true])
        #expect(sections[0].voters.map(\.isMe) == [true, false])
        #expect(sections[1].voters.map(\.accountIdHex) == [blocked, Self.voter(3)])
        #expect(sections[1].voters.map(\.isBlocked) == [true, false])
        #expect(sections[2].voters.isEmpty)
    }

    @Test func duplicateVotersAndUnknownOptionsAreIgnored() {
        let sections = PollVotesPresentation.sections(
            options: Self.options,
            votes: [
                Self.vote(1, ["0", "0", "9"], at: 1),
                Self.vote(1, ["2"], at: 2)
            ],
            blockedAccountIds: [],
            myAccountIdHex: nil
        )
        #expect(sections.map { $0.voters.count } == [1, 0, 0])
    }

    // MARK: Stale results

    @Test func aLateResultForAnotherPollIsDiscarded() async throws {
        let source = GatedPollVotesSource()
        source.gate(Self.subjectA)
        source.respond(Self.subjectB, with: PollVotePageFfi(votes: [Self.vote(2, at: 2)], hasMoreAfter: false))
        let model = PollVotesModel()

        let stale = Task { await model.load(Self.subjectA, using: source) }
        try await source.waitUntilWaiting(Self.subjectA)
        await model.load(Self.subjectB, using: source)
        source.release(Self.subjectA, with: PollVotePageFfi(votes: [Self.vote(1, at: 1)], hasMoreAfter: false))
        await stale.value

        #expect(model.subject == Self.subjectB)
        #expect(model.votes.map(\.voterAccountIdHex) == [Self.voter(2)])
        #expect(model.phase == .loaded)
    }

    @Test func switchingAccountsClearsTheOtherAccountsVotesImmediately() async throws {
        let source = GatedPollVotesSource()
        source.respond(Self.subjectA, with: PollVotePageFfi(votes: [Self.vote(1, at: 1)], hasMoreAfter: false))
        let model = PollVotesModel()
        await model.load(Self.subjectA, using: source)

        let bob = PollVotesSubject(accountRef: "bob", groupIdHex: Self.group, pollEventId: Self.pollA)
        source.gate(bob)
        let switched = Task { await model.load(bob, using: source) }
        try await source.waitUntilWaiting(bob)

        #expect(model.subject == bob)
        #expect(model.votes.isEmpty)
        #expect(model.phase == .loading)

        source.release(bob, with: PollVotePageFfi(votes: [], hasMoreAfter: false))
        await switched.value
        #expect(model.phase == .loaded)
    }

    @Test func aSupersededReloadOfTheSamePollIsDiscarded() async throws {
        let source = GatedPollVotesSource()
        source.gate(Self.subjectA)
        let model = PollVotesModel()

        let older = Task { await model.load(Self.subjectA, using: source) }
        try await source.waitUntilWaiting(Self.subjectA)
        let olderContinuation = try #require(source.takeWaiter(Self.subjectA))

        let newer = Task { await model.load(Self.subjectA, using: source) }
        try await source.waitUntilWaiting(Self.subjectA)
        source.release(Self.subjectA, with: PollVotePageFfi(votes: [Self.vote(2, at: 2)], hasMoreAfter: false))
        await newer.value

        olderContinuation.resume(returning: PollVotePageFfi(votes: [Self.vote(1, at: 1)], hasMoreAfter: false))
        await older.value

        #expect(model.votes.map(\.voterAccountIdHex) == [Self.voter(2)])
        #expect(model.phase == .loaded)
    }

    @Test func aCancelledLoadPublishesNothing() async throws {
        let source = GatedPollVotesSource()
        source.gate(Self.subjectA)
        let model = PollVotesModel()

        let load = Task { await model.load(Self.subjectA, using: source) }
        try await source.waitUntilWaiting(Self.subjectA)
        load.cancel()
        source.release(Self.subjectA, with: PollVotePageFfi(votes: [Self.vote(1, at: 1)], hasMoreAfter: false))
        await load.value

        #expect(model.votes.isEmpty)
        #expect(model.phase == .loading)
    }

    // MARK: Runtime projection invalidation

    private static let me = voter(0x11)
    private static let watch = PollVotesWatch(accountIdHex: me, groupIdHex: group, pollEventId: pollA)

    private func projectionUpdate(
        account: String? = nil,
        group: String? = nil,
        messages: [TimelineMessageRecordFfi] = [],
        changes: [TimelineMessageChangeFfi]
    ) -> RuntimeProjectionUpdateFfi {
        RuntimeProjectionUpdateFfi(accountIdHex: account ?? Self.me, accountLabel: "alice",
            update: TimelineProjectionUpdateFfi(groupIdHex: group ?? Self.group, messages: messages, changes: changes,
                chatListRow: nil, chatListTrigger: .snapshotRefresh))
    }

    @Test func aWatchMatchesUpsertsRemovalsAndMessagesForItsPollOnly() {
        let row = pollRecord(id: Self.pollA, votes: [1, 0])
        let reVote = projectionUpdate(changes: [.upsert(trigger: .messageEditedOrReprojected, message: row)])
        #expect(Self.watch.isTouched(by: reVote))
        #expect(Self.watch.isTouched(by: projectionUpdate(account: Self.me.uppercased(),
            changes: [.upsert(trigger: .messageEditedOrReprojected, message: row)])))
        #expect(Self.watch.isTouched(by: projectionUpdate(changes: [.remove(messageIdHex: Self.pollA, reason: .invalidated)])))
        #expect(Self.watch.isTouched(by: projectionUpdate(messages: [row], changes: [])))

        let otherPoll = pollRecord(id: Self.pollB, votes: [1, 0])
        #expect(!Self.watch.isTouched(by: projectionUpdate(changes: [.upsert(trigger: .messageEditedOrReprojected, message: otherPoll)])))
        #expect(!Self.watch.isTouched(by: projectionUpdate(group: String(repeating: "d", count: 64),
            changes: [.upsert(trigger: .messageEditedOrReprojected, message: row)])))
        #expect(!Self.watch.isTouched(by: projectionUpdate(account: Self.voter(0x22),
            changes: [.upsert(trigger: .messageEditedOrReprojected, message: row)])))
    }

    @Test func invalidationCountsOnlyWhileThePollIsWatched() {
        let invalidation = PollVotesInvalidation()
        let event = MarmotEventFfi.projectionUpdated(update: projectionUpdate(
            changes: [.upsert(trigger: .messageEditedOrReprojected, message: pollRecord(id: Self.pollA, votes: [1, 0]))]))

        invalidation.observe(event)
        #expect(invalidation.revision == 0)

        invalidation.begin(Self.watch)
        invalidation.observe(event)
        invalidation.observe(.historyNoticesChanged(accountIdHex: Self.me, accountLabel: "alice"))
        #expect(invalidation.revision == 1)

        // A sheet for another poll ending must not stop this watch.
        invalidation.end(PollVotesWatch(accountIdHex: Self.me, groupIdHex: Self.group, pollEventId: Self.pollB))
        invalidation.observe(event)
        #expect(invalidation.revision == 2)

        invalidation.end(Self.watch)
        invalidation.observe(event)
        #expect(invalidation.revision == 2)
    }

    /// A re-vote for the same option changes only the voter's `votedAt`: the
    /// window path sees an identical poll row and skips it, so the runtime
    /// projection event MDK emits for the response is what invalidates.
    @Test func aSameTallyReVoteInvalidatesThroughRuntimeEventsAfterTheWindowDeduplicatesIt() throws {
        let row = pollRecord(id: Self.pollA, votes: [2, 1])
        let store = TimelineStore(appState: nil, groupIdHex: Self.group)
        store.applyConversationWindowPage(TimelinePageFfi(messages: [row], hasMoreBefore: false, hasMoreAfter: false))
        let windowRevision = store.pollReprojectionRevision(for: Self.pollA)
        store.applyConversationWindowPage(TimelinePageFfi(messages: [row], hasMoreBefore: false, hasMoreAfter: false))
        #expect(store.pollReprojectionRevision(for: Self.pollA) == windowRevision)

        let state = AppState.test(client: try MarmotClient.testClient())
        state.accountStore.accounts = [
            AccountSummaryFfi(label: "alice", accountIdHex: Self.me, localSigning: true, signedOut: false, running: true)
        ]
        state.activeAccountRef = "alice"
        state.setPhase(.ready)
        let generation = try #require(state.runtimeEventsGeneration)
        state.pollVotesInvalidation.begin(Self.watch)

        let reVote = MarmotEventFfi.projectionUpdated(update: projectionUpdate(
            changes: [.upsert(trigger: .messageEditedOrReprojected, message: row)]))
        state.handleRuntimeEvent(reVote, generation: generation)
        #expect(state.pollVotesInvalidation.revision == 1)
        state.handleRuntimeEvent(reVote, generation: generation)
        #expect(state.pollVotesInvalidation.revision == 2)

        // Events from a replaced runtime are ignored.
        state.handleRuntimeEvent(reVote, generation: generation - 1)
        #expect(state.pollVotesInvalidation.revision == 2)
    }

    // MARK: Avatars

    @Test func onlyConversationIdentitiesProvideAnAvatarAndNeverForBlockedVoters() {
        let asset = AvatarAssetFfi(target: "t", reference: "r", availability: .ready, acquisition: nil,
                                   contentRevision: 1, byteCount: 10)
        let identity = ConversationIdentityFfi(accountIdHex: Self.voter(3), displayName: "Alice",
            avatar: .placeholder(stableSeed: "s", source: .peerProfile), hasCachedProfile: true, avatarAsset: asset)
        let voter = PollVotesPresentation.Voter(accountIdHex: Self.voter(3), votedAt: 1, isBlocked: false, isMe: false)
        let blocked = PollVotesPresentation.Voter(accountIdHex: Self.voter(3), votedAt: 1, isBlocked: true, isMe: false)

        #expect(PollVotesPresentation.avatarSource(for: voter, identity: identity) == .native(asset))
        #expect(PollVotesPresentation.avatarSource(for: voter, identity: nil) == .monogram)
        #expect(PollVotesPresentation.avatarSource(for: blocked, identity: identity) == .monogram)
    }

    // MARK: Fixtures

    private func pollRecord(
        id: String,
        votes: [UInt64]?,
        deleted: Bool = false,
        kind: UInt64 = MessageSemantics.kindPoll
    ) -> TimelineMessageRecordFfi {
        let poll = votes.map { votes in
            PollProjectionFfi(
                question: "Lunch?",
                options: votes.enumerated().map {
                    PollOptionResultFfi(id: String($0.offset), label: "Option \($0.offset)", votes: $0.element)
                },
                pollType: .singleChoice,
                participants: votes.reduce(0, +),
                localSelection: [],
                creator: Self.voter(9),
                endsAt: nil,
                open: true
            )
        }
        return TimelineMessageRecordFfi(
            messageIdHex: id, sourceMessageIdHex: id, direction: "received",
            groupIdHex: Self.group, sender: Self.voter(9), plaintext: "Lunch?",
            contentTokens: .emptyDocument, kind: kind, tags: [],
            timelineAt: 1, receivedAt: 1, replyToMessageIdHex: nil, replyPreview: nil,
            mediaJson: nil, media: [], agentTextStreamJson: nil, groupSystem: nil, poll: poll,
            reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []), edit: nil,
            deleted: deleted, deletedByMessageIdHex: nil, invalidationStatus: nil
        )
    }
}

/// Returns scripted pages in order and records every request.
private nonisolated final class ScriptedPollVotesSource: PollVotesDataSource {
    struct Call: Equatable {
        let subject: PollVotesSubject
        let cursor: PollVotesCursor?
        let limit: UInt32
    }

    private struct State {
        var pages: [PollVotePageFfi]
        var calls: [Call] = []
    }

    private let state: Mutex<State>
    private let failure: (any Error)?

    init(pages: [PollVotePageFfi], failure: (any Error)? = nil) {
        state = Mutex(State(pages: pages))
        self.failure = failure
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func pollVotesPage(for subject: PollVotesSubject, after cursor: PollVotesCursor?, limit: UInt32) async throws -> PollVotePageFfi {
        let page = state.withLock { state -> PollVotePageFfi in
            state.calls.append(Call(subject: subject, cursor: cursor, limit: limit))
            guard !state.pages.isEmpty else { return PollVotePageFfi(votes: [], hasMoreAfter: false) }
            return state.pages.removeFirst()
        }
        if let failure { throw failure }
        return page
    }
}

/// Holds requests for gated subjects until the test releases them, so a test
/// can deliver a page after a newer load has started.
private nonisolated final class GatedPollVotesSource: PollVotesDataSource {
    private struct State {
        var gated: Set<PollVotesSubject> = []
        var responses: [PollVotesSubject: PollVotePageFfi] = [:]
        var waiters: [PollVotesSubject: CheckedContinuation<PollVotePageFfi, any Error>] = [:]
        var requestedCursors: [PollVotesSubject: [PollVotesCursor?]] = [:]
    }

    private let state = Mutex(State())

    func gate(_ subject: PollVotesSubject) {
        state.withLock { _ = $0.gated.insert(subject) }
    }

    func respond(_ subject: PollVotesSubject, with page: PollVotePageFfi) {
        state.withLock { $0.responses[subject] = page }
    }

    func cursors(for subject: PollVotesSubject) -> [PollVotesCursor?] {
        state.withLock { $0.requestedCursors[subject] ?? [] }
    }

    func takeWaiter(_ subject: PollVotesSubject) -> CheckedContinuation<PollVotePageFfi, any Error>? {
        state.withLock { $0.waiters.removeValue(forKey: subject) }
    }

    /// Resumes the held request and stops gating the subject.
    func release(_ subject: PollVotesSubject, with page: PollVotePageFfi) {
        let waiter = state.withLock { state -> CheckedContinuation<PollVotePageFfi, any Error>? in
            state.gated.remove(subject)
            state.responses[subject] = page
            return state.waiters.removeValue(forKey: subject)
        }
        waiter?.resume(returning: page)
    }

    func waitUntilWaiting(_ subject: PollVotesSubject) async throws {
        for _ in 0..<10_000 {
            if state.withLock({ $0.waiters[subject] != nil }) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for a request for \(subject.pollEventId)")
    }

    func pollVotesPage(for subject: PollVotesSubject, after cursor: PollVotesCursor?, limit: UInt32) async throws -> PollVotePageFfi {
        let immediate = state.withLock { state -> PollVotePageFfi? in
            state.requestedCursors[subject, default: []].append(cursor)
            return state.gated.contains(subject)
                ? nil
                : (state.responses[subject] ?? PollVotePageFfi(votes: [], hasMoreAfter: false))
        }
        if let immediate { return immediate }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.waiters[subject] = continuation }
        }
    }
}

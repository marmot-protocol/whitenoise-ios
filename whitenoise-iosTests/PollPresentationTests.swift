import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct PollPresentationTests {
    private static func poll(
        type: PollTypeFfi = .singleChoice,
        votes: [UInt64] = [0, 0, 0],
        participants: UInt64 = 0,
        localSelection: [String] = [],
        endsAt: UInt64? = nil,
        open: Bool = true
    ) -> PollProjectionFfi {
        PollProjectionFfi(
            question: "Lunch?",
            options: votes.enumerated().map {
                PollOptionResultFfi(id: String($0.offset), label: "Option \($0.offset)", votes: $0.element)
            },
            pollType: type,
            participants: participants,
            localSelection: localSelection,
            creator: String(repeating: "a", count: 64),
            endsAt: endsAt,
            open: open
        )
    }

    // MARK: Selection

    @Test func singleChoiceTapReplacesTheVoteAndIgnoresTheCurrentChoice() {
        let order = ["0", "1", "2"]
        #expect(PollPresentation.toggledSelection(current: [], option: "1", pollType: .singleChoice, optionOrder: order) == ["1"])
        #expect(PollPresentation.toggledSelection(current: ["1"], option: "2", pollType: .singleChoice, optionOrder: order) == ["2"])
        #expect(PollPresentation.toggledSelection(current: ["1"], option: "1", pollType: .singleChoice, optionOrder: order) == nil)
    }

    @Test func multipleChoiceTogglesInOptionOrderButNeverWithdrawsTheLastVote() {
        let order = ["0", "1", "2"]
        #expect(PollPresentation.toggledSelection(current: ["2"], option: "0", pollType: .multipleChoice, optionOrder: order) == ["0", "2"])
        #expect(PollPresentation.toggledSelection(current: ["0", "2"], option: "2", pollType: .multipleChoice, optionOrder: order) == ["0"])
        #expect(PollPresentation.toggledSelection(current: ["0"], option: "0", pollType: .multipleChoice, optionOrder: order) == nil)
    }

    @Test func unknownOptionIsIgnored() {
        #expect(PollPresentation.toggledSelection(current: [], option: "9", pollType: .singleChoice, optionOrder: ["0", "1"]) == nil)
    }

    // MARK: Optimistic overlay

    @Test func firstLocalVoteAddsAParticipantAndAVote() {
        let result = PollPresentation.applyingLocalSelection(["1"], to: Self.poll(votes: [2, 0, 1], participants: 3))
        #expect(result.options.map(\.votes) == [2, 1, 1])
        #expect(result.participants == 4)
        #expect(result.localSelection == ["1"])
    }

    @Test func changedLocalVoteMovesTheVoteWithoutAddingAParticipant() {
        let base = Self.poll(votes: [2, 1, 1], participants: 4, localSelection: ["1"])
        let result = PollPresentation.applyingLocalSelection(["2"], to: base)
        #expect(result.options.map(\.votes) == [2, 0, 2])
        #expect(result.participants == 4)
    }

    @Test func overlayNeverUnderflowsAStaleZeroCount() {
        let base = Self.poll(votes: [0, 0, 0], participants: 1, localSelection: ["0"])
        #expect(PollPresentation.applyingLocalSelection(["1"], to: base).options.map(\.votes) == [0, 1, 0])
    }

    // MARK: Deadline and results

    @Test func pollClosesAtItsDeadlineEvenWhenProjectedOpen() {
        let base = Self.poll(endsAt: 1_000)
        #expect(PollPresentation.isOpen(base, now: Date(timeIntervalSince1970: 1_000)))
        #expect(!PollPresentation.isOpen(base, now: Date(timeIntervalSince1970: 1_001)))
        #expect(!PollPresentation.isOpen(Self.poll(open: false), now: Date(timeIntervalSince1970: 0)))
    }

    @Test func resultFractionIsShareOfVoters() {
        #expect(PollPresentation.fraction(votes: 0, participants: 0) == 0)
        #expect(PollPresentation.fraction(votes: 1, participants: 4) == 0.25)
        #expect(PollPresentation.fraction(votes: 9, participants: 4) == 1)
    }

    // MARK: Draft validation

    @Test func draftSubmitsTrimmedSingleLineTextAndSkipsBlankRows() throws {
        var draft = PollDraft()
        draft.question = "  Where\nto eat?  "
        draft.options = [" Tacos ", "", "Ramen\u{202E}"]
        let submission = try draft.validated(now: Date(timeIntervalSince1970: 100)).get()
        #expect(submission.question == "Where to eat?")
        #expect(submission.options == ["Tacos", "Ramen"])
        #expect(submission.pollType == .singleChoice)
        #expect(submission.endsAt == nil)
    }

    @Test func draftDurationAndMultipleAnswersMapToMDKFields() throws {
        var draft = PollDraft()
        draft.question = "Days?"
        draft.options = ["Mon", "Tue"]
        draft.allowsMultipleAnswers = true
        draft.duration = .oneDay
        let submission = try draft.validated(now: Date(timeIntervalSince1970: 100)).get()
        #expect(submission.pollType == .multipleChoice)
        #expect(submission.endsAt == 100 + 86_400)
    }

    @Test func draftRejectsInputMDKWouldRefuse() {
        var draft = PollDraft()
        draft.options = ["A", "B"]
        #expect(draft.validated(now: .now) == .failure(.missingQuestion))

        draft.question = String(repeating: "q", count: PollDraft.maximumQuestionBytes + 1)
        #expect(draft.validated(now: .now) == .failure(.questionTooLong))

        draft.question = "Q"
        draft.options = ["A", "  "]
        #expect(draft.validated(now: .now) == .failure(.tooFewOptions))

        draft.options = ["A", String(repeating: "é", count: 129)]
        #expect(draft.validated(now: .now) == .failure(.optionTooLong))

        draft.options = ["Yes", "yes"]
        #expect(draft.validated(now: .now) == .failure(.duplicateOption))
    }

    @Test func draftKeepsBetweenTwoAndTenOptionRows() {
        var draft = PollDraft()
        #expect(!draft.canRemoveOption)
        draft.removeOptions(at: IndexSet(integer: 0))
        #expect(draft.options.count == 2)
        for _ in 0..<20 { draft.addOption() }
        #expect(draft.options.count == PollDraft.maximumOptions)
        #expect(!draft.canAddOption)
    }

    // MARK: Classification and previews

    @Test func kind1068ClassifiesAsAPollAndPreviewsAsOne() {
        #expect(MessageSemantics.classify(kind: MessageSemantics.kindPoll, tags: []) == .poll)
        let record = AppMessageRecordFfi(
            messageIdHex: String(repeating: "b", count: 64),
            direction: "received",
            groupIdHex: String(repeating: "c", count: 64),
            sender: String(repeating: "a", count: 64),
            plaintext: "Lunch?",
            kind: MessageSemantics.kindPoll,
            tags: [],
            recordedAt: 1,
            receivedAt: 1
        )
        #expect(MessagePreview.isPreviewable(record))
        #expect(MessagePreview.body(record) == MessagePreview.pollPreview(question: "Lunch?"))
        #expect(MessagePreview.pollPreview(question: "Lunch?").contains("Lunch?"))
    }

    @Test func pollAppearsInTheComposerMenuOnlyWhenAvailable() {
        #expect(!ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true).contains(.poll))
        #expect(ComposerAttachmentOption.available(cameraAvailable: true, gifsAvailable: true, pollsAvailable: true).last == .poll)
    }
}

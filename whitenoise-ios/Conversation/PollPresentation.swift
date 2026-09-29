import Foundation
import MarmotKit

/// Pure decisions for rendering and voting on MDK-projected polls.
nonisolated enum PollPresentation {
    /// MDK computes `open` when the row is read; a row read before the deadline
    /// must still close once the deadline passes.
    static func isOpen(_ poll: PollProjectionFfi, now: Date) -> Bool {
        guard poll.open else { return false }
        guard let endsAt = poll.endsAt else { return true }
        return now.timeIntervalSince1970 <= TimeInterval(endsAt)
    }

    /// The selection a tap on `optionId` produces, or nil when the tap changes
    /// nothing. MDK accepts only non-empty selections, so a vote can be changed
    /// but never withdrawn.
    static func toggledSelection(
        current: [String],
        option optionId: String,
        pollType: PollTypeFfi,
        optionOrder: [String]
    ) -> [String]? {
        guard optionOrder.contains(optionId) else { return nil }
        switch pollType {
        case .singleChoice:
            return current == [optionId] ? nil : [optionId]
        case .multipleChoice:
            var selected = Set(current)
            if selected.contains(optionId) {
                selected.remove(optionId)
            } else {
                selected.insert(optionId)
            }
            guard !selected.isEmpty else { return nil }
            return optionOrder.filter(selected.contains)
        }
    }

    /// Applies an in-flight local vote so the tap is reflected before MDK
    /// re-projects the row.
    static func applyingLocalSelection(_ selection: [String], to poll: PollProjectionFfi) -> PollProjectionFfi {
        let previous = Set(poll.localSelection)
        let next = Set(selection)
        guard previous != next else { return poll }
        var result = poll
        result.options = poll.options.map { option in
            var option = option
            if previous.contains(option.id), !next.contains(option.id) {
                option.votes = option.votes > 0 ? option.votes - 1 : 0
            } else if !previous.contains(option.id), next.contains(option.id) {
                option.votes += 1
            }
            return option
        }
        if previous.isEmpty, !next.isEmpty {
            result.participants += 1
        }
        result.localSelection = selection
        return result
    }

    /// Share of voters who picked the option, for the result bar.
    static func fraction(votes: UInt64, participants: UInt64) -> Double {
        guard participants > 0 else { return 0 }
        return min(1, Double(votes) / Double(participants))
    }
}

/// Composer state for a new poll, validated against MDK's poll profile before
/// the async send starts.
nonisolated struct PollDraft: Equatable {
    static let minimumOptions = 2
    static let maximumOptions = 10
    static let maximumQuestionBytes = 1_024
    static let maximumOptionBytes = 256

    enum Duration: String, CaseIterable, Identifiable {
        case none, oneHour, oneDay, oneWeek

        var id: String { rawValue }

        var seconds: UInt64? {
            switch self {
            case .none: nil
            case .oneHour: 60 * 60
            case .oneDay: 24 * 60 * 60
            case .oneWeek: 7 * 24 * 60 * 60
            }
        }
    }

    enum Issue: Error, Equatable {
        case missingQuestion
        case questionTooLong
        case tooFewOptions
        case optionTooLong
        case duplicateOption
    }

    struct Submission: Equatable {
        let question: String
        let options: [String]
        let pollType: PollTypeFfi
        let endsAt: UInt64?
    }

    var question = ""
    var options = ["", ""]
    var allowsMultipleAnswers = false
    var duration = Duration.none

    var canAddOption: Bool { options.count < Self.maximumOptions }
    var canRemoveOption: Bool { options.count > Self.minimumOptions }

    mutating func addOption() {
        guard canAddOption else { return }
        options.append("")
    }

    mutating func removeOptions(at offsets: IndexSet) {
        let remaining = options.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        options = remaining.count >= Self.minimumOptions
            ? remaining
            : remaining + Array(repeating: "", count: Self.minimumOptions - remaining.count)
    }

    /// Blank option rows are ignored so an unused trailing row never blocks Send.
    func validated(now: Date) -> Result<Submission, Issue> {
        let question = Self.normalized(question)
        guard !question.isEmpty else { return .failure(.missingQuestion) }
        guard question.utf8.count <= Self.maximumQuestionBytes else { return .failure(.questionTooLong) }
        let labels = options.map(Self.normalized).filter { !$0.isEmpty }
        guard labels.count >= Self.minimumOptions else { return .failure(.tooFewOptions) }
        guard labels.allSatisfy({ $0.utf8.count <= Self.maximumOptionBytes }) else {
            return .failure(.optionTooLong)
        }
        let folded = labels.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard Set(folded).count == folded.count else { return .failure(.duplicateOption) }
        let endsAt = duration.seconds.map { UInt64(max(0, now.timeIntervalSince1970)) + $0 }
        return .success(Submission(
            question: question,
            options: labels,
            pollType: allowsMultipleAnswers ? .multipleChoice : .singleChoice,
            endsAt: endsAt
        ))
    }

    /// MDK rejects control characters, bidi overrides/isolates, and surrounding
    /// whitespace; line breaks become spaces.
    static func normalized(_ value: String) -> String {
        let scalars = value.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if CharacterSet.newlines.contains(scalar) { return " " }
            if scalar.properties.generalCategory == .control || isBidiControl(scalar) { return nil }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    private static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }
}

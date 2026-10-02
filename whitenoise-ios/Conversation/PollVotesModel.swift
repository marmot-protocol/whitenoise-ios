import Foundation
import MarmotKit

/// The poll a View votes sheet reads, in one account. Results for any other
/// subject are never shown.
nonisolated struct PollVotesSubject: Hashable, Sendable {
    let accountRef: String
    let groupIdHex: String
    let pollEventId: String
}

/// MDK's `(voted_at, voter_account_id_hex)` page cursor.
nonisolated struct PollVotesCursor: Equatable, Sendable {
    let votedAt: UInt64
    let voterAccountIdHex: String
}

/// Reads one page of per-voter poll results off the MainActor.
nonisolated protocol PollVotesDataSource: Sendable {
    func pollVotesPage(for subject: PollVotesSubject, after cursor: PollVotesCursor?, limit: UInt32) async throws -> PollVotePageFfi
}

extension MarmotClient: PollVotesDataSource {
    nonisolated func pollVotesPage(
        for subject: PollVotesSubject,
        after cursor: PollVotesCursor?,
        limit: UInt32
    ) async throws -> PollVotePageFfi {
        try await pollVotes(
            accountRef: subject.accountRef,
            groupIdHex: subject.groupIdHex,
            pollEventId: subject.pollEventId,
            afterVotedAt: cursor?.votedAt,
            afterVoterAccountIdHex: cursor?.voterAccountIdHex,
            limit: limit
        )
    }
}

nonisolated enum PollVotesPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Loads every voter for one poll, re-reading from the first page on each
/// reprojection. A load publishes only once all pages arrived, so a reload
/// never shows a partial list in place of the previous one.
@MainActor
@Observable
final class PollVotesModel {
    static let pageLimit: UInt32 = 100
    /// Bounds a misbehaving cursor; 1,000 pages is 100,000 voters.
    static let maximumPages = 1_000

    private(set) var subject: PollVotesSubject?
    private(set) var votes: [PollVoteFfi] = []
    private(set) var phase: PollVotesPhase = .idle
    @ObservationIgnored private var loadToken: UInt64 = 0

    func load(
        _ subject: PollVotesSubject,
        using dataSource: any PollVotesDataSource,
        errorMessage: (Error) -> String = { UserFacingError.message(for: $0) }
    ) async {
        loadToken &+= 1
        let token = loadToken
        if self.subject != subject {
            self.subject = subject
            votes = []
        }
        phase = .loading
        var collected: [PollVoteFfi] = []
        var cursor: PollVotesCursor?
        do {
            for _ in 0..<Self.maximumPages {
                let page = try await dataSource.pollVotesPage(for: subject, after: cursor, limit: Self.pageLimit)
                guard isCurrent(token, subject) else { return }
                collected.append(contentsOf: page.votes)
                guard let next = PollVotesPresentation.nextCursor(after: page, previous: cursor) else { break }
                cursor = next
            }
            guard isCurrent(token, subject) else { return }
            votes = collected
            phase = .loaded
        } catch {
            guard isCurrent(token, subject), !(error is CancellationError) else { return }
            phase = .failed(errorMessage(error))
        }
    }

    /// A late page from a cancelled or superseded load is discarded.
    private func isCurrent(_ token: UInt64, _ subject: PollVotesSubject) -> Bool {
        !Task.isCancelled && token == loadToken && self.subject == subject
    }
}

/// Pure decisions for the View votes sheet.
nonisolated enum PollVotesPresentation {
    struct Voter: Identifiable, Equatable {
        /// Lowercased so block and self checks match regardless of hex case.
        let accountIdHex: String
        let votedAt: UInt64
        let isBlocked: Bool
        let isMe: Bool

        var id: String { accountIdHex }
    }

    struct OptionSection: Identifiable, Equatable {
        let id: String
        let label: String
        let voters: [Voter]
    }

    enum Content: Equatable {
        case loading
        case failed(String)
        /// The poll row was deleted or is no longer a valid poll.
        case unavailable
        case noVotes
        case votes([OptionSection])
    }

    /// The next page's cursor, or nil when paging is done. A cursor that does
    /// not advance ends paging rather than re-reading the same page forever.
    static func nextCursor(after page: PollVotePageFfi, previous: PollVotesCursor?) -> PollVotesCursor? {
        guard page.hasMoreAfter, let last = page.votes.last else { return nil }
        let next = PollVotesCursor(votedAt: last.votedAt, voterAccountIdHex: last.voterAccountIdHex)
        return next == previous ? nil : next
    }

    /// One section per poll option in display order, each listing its voters
    /// in MDK's vote order. A voter appears once per option they chose;
    /// option ids the poll doesn't define are ignored.
    static func sections(
        options: [PollOptionResultFfi],
        votes: [PollVoteFfi],
        blockedAccountIds: Set<String>,
        myAccountIdHex: String?
    ) -> [OptionSection] {
        let blocked = Set(blockedAccountIds.map { $0.lowercased() })
        let me = myAccountIdHex?.lowercased()
        var votersByOption: [String: [Voter]] = [:]
        var seenVoters = Set<String>()
        for vote in votes {
            let accountIdHex = vote.voterAccountIdHex.lowercased()
            guard seenVoters.insert(accountIdHex).inserted else { continue }
            let voter = Voter(
                accountIdHex: accountIdHex,
                votedAt: vote.votedAt,
                isBlocked: blocked.contains(accountIdHex),
                isMe: accountIdHex == me
            )
            for optionId in Set(vote.optionIds) {
                votersByOption[optionId, default: []].append(voter)
            }
        }
        return options.map { option in
            OptionSection(
                id: option.id,
                label: ContentSanitizer.messageBody(option.label),
                voters: votersByOption[option.id] ?? []
            )
        }
    }

    /// What the sheet shows. A deleted poll, or an empty page (MDK's answer
    /// for a missing, hidden or deleted row), is an empty state, not an error.
    static func content(
        isPollAvailable: Bool,
        phase: PollVotesPhase,
        sections: [OptionSection]
    ) -> Content {
        guard isPollAvailable else { return .unavailable }
        let hasVoters = sections.contains { !$0.voters.isEmpty }
        switch phase {
        case .idle, .loading:
            return hasVoters ? .votes(sections) : .loading
        case .failed(let message):
            return .failed(message)
        case .loaded:
            return hasVoters ? .votes(sections) : .noVotes
        }
    }

    static func votedAtLabel(_ timestamp: UInt64, locale: Locale) -> String? {
        guard timestamp > 0 else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(style)
    }
}

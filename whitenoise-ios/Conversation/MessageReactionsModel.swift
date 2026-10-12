import Foundation
import MarmotKit

/// The message a reaction details sheet reads, in one account and runtime.
/// Results for any other subject are never shown.
nonisolated struct MessageReactionsSubject: Hashable, Sendable {
    let accountRef: String
    let groupIdHex: String
    let messageIdHex: String
    let runtimeGeneration: Int
}

/// Reads every effective reaction on one message off the MainActor.
nonisolated protocol MessageReactionsDataSource: Sendable {
    func messageReactions(for subject: MessageReactionsSubject) async throws -> [TimelineUserReactionFfi]
}

extension MarmotClient: MessageReactionsDataSource {
    nonisolated func messageReactions(for subject: MessageReactionsSubject) async throws -> [TimelineUserReactionFfi] {
        try await messageReactions(
            accountRef: subject.accountRef,
            groupIdHex: subject.groupIdHex,
            messageIdHex: subject.messageIdHex
        )
    }
}

nonisolated enum MessageReactionsPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Loads MDK's complete reactions for one message. A reload keeps the previous
/// list until it completes; a new subject discards it immediately.
@MainActor
@Observable
final class MessageReactionsModel {
    private(set) var subject: MessageReactionsSubject?
    private(set) var reactions: [TimelineUserReactionFfi] = []
    /// Whether `reactions` holds a completed read for `subject`.
    private(set) var hasLoaded = false
    private(set) var phase: MessageReactionsPhase = .idle
    @ObservationIgnored private var loadToken: UInt64 = 0

    func load(
        _ subject: MessageReactionsSubject,
        using dataSource: any MessageReactionsDataSource,
        errorMessage: (Error) -> String = { UserFacingError.message(for: $0) }
    ) async {
        loadToken &+= 1
        let token = loadToken
        if self.subject != subject {
            self.subject = subject
            reactions = []
            hasLoaded = false
        }
        phase = .loading
        do {
            let result = try await dataSource.messageReactions(for: subject)
            guard isCurrent(token, subject) else { return }
            reactions = result
            hasLoaded = true
            phase = .loaded
        } catch {
            guard isCurrent(token, subject), !(error is CancellationError) else { return }
            phase = .failed(errorMessage(error))
        }
    }

    /// A late read from a cancelled or superseded load is discarded.
    private func isCurrent(_ token: UInt64, _ subject: MessageReactionsSubject) -> Bool {
        !Task.isCancelled && token == loadToken && self.subject == subject
    }
}

/// Pure decisions for the reaction details sheet.
nonisolated enum ReactionDetailsPresentation {
    typealias Details = ConversationViewModel.ReactionDetails

    enum Content: Equatable {
        /// The first read is in flight and no complete list is known yet.
        case loading
        case failed(String)
        /// No reactions, or MDK no longer exposes the message.
        case empty
        /// `refreshError` is set when a later re-read failed; the list is the
        /// last complete read.
        case details(Details, refreshError: String?)
    }

    /// A progress indicator appears only when the first read is slower than
    /// this, so a fast local read never flashes a spinner.
    static let loadingIndicatorDelay: Duration = .milliseconds(300)

    /// What the sheet shows. `projected` is the conversation window's bounded
    /// preview for the message (with local optimistic changes), or nil when
    /// the message is not in the installed window. Before the first read
    /// completes, a preview that is already complete is shown as is.
    static func content(
        phase: MessageReactionsPhase,
        hasLoaded: Bool,
        reactions: [TimelineUserReactionFfi],
        projected: Details?,
        me: String
    ) -> Content {
        let failure: String? = if case .failed(let message) = phase { message } else { nil }
        guard hasLoaded else {
            if let failure { return .failed(failure) }
            if let projected, !projected.groups.isEmpty, !projected.isTruncated {
                return .details(projected, refreshError: nil)
            }
            return .loading
        }
        let details = completeDetails(reactions, projected: projected, me: me)
        if details.groups.isEmpty {
            if let failure { return .failed(failure) }
            return .empty
        }
        return .details(details, refreshError: failure)
    }

    /// Groups MDK's complete per-sender reactions by emoji.
    ///
    /// The viewer's own reactions follow the window projection, which carries
    /// pending react/un-react changes and the window's `viewerReacted` flag.
    /// When the window lists every reaction kind, an emoji it no longer has is
    /// dropped too, so a read finished just before a newer revision doesn't
    /// briefly resurrect a removed reaction.
    static func completeDetails(
        _ reactions: [TimelineUserReactionFfi],
        projected: Details?,
        me: String
    ) -> Details {
        var others: [String: [String]] = [:]
        var mineInRead: Set<String> = []
        var earliest: [String: (reactedAt: UInt64, id: String)] = [:]
        for reaction in reactions where !reaction.emoji.isEmpty && !reaction.sender.isEmpty {
            if reaction.sender == me {
                mineInRead.insert(reaction.emoji)
            } else if others[reaction.emoji]?.contains(reaction.sender) != true {
                others[reaction.emoji, default: []].append(reaction.sender)
            }
            if !reaction.reactionMessageIdHex.isEmpty {
                let candidate = (reactedAt: reaction.reactedAt, id: reaction.reactionMessageIdHex)
                if let current = earliest[reaction.emoji], (current.reactedAt, current.id) <= (candidate.reactedAt, candidate.id) {
                    continue
                }
                earliest[reaction.emoji] = candidate
            }
        }

        let projectedGroups = Dictionary(
            (projected?.groups ?? []).map { ($0.emoji, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let listsEveryKind = projected.map { $0.omittedKinds == 0 } ?? false

        var emojis = Set(others.keys).union(mineInRead)
        emojis.formUnion(projectedGroups.values.filter(\.mine).map(\.emoji))
        if listsEveryKind {
            emojis.formIntersection(projectedGroups.keys)
        }

        var groups: [Details.EmojiGroup] = []
        for emoji in emojis {
            let mine: Bool
            if let group = projectedGroups[emoji] {
                mine = group.mine
            } else {
                mine = !listsEveryKind && mineInRead.contains(emoji)
            }
            var senders = others[emoji] ?? []
            if mine, !me.isEmpty { senders.append(me) }
            guard !senders.isEmpty else { continue }
            groups.append(Details.EmojiGroup(
                emoji: emoji,
                senders: senders,
                mine: mine,
                reactionMessageIdHex: projectedGroups[emoji]?.reactionMessageIdHex ?? earliest[emoji]?.id
            ))
        }
        groups.sort { lhs, rhs in
            lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
        }
        return Details(groups: groups)
    }

    /// The emoji filters the sheet can offer, or nil while there is no list.
    static func availableEmojis(in content: Content) -> [String]? {
        guard case .details(let details, _) = content else { return nil }
        return details.groups.map(\.emoji)
    }

    /// Keeps the selected filter while the list is unknown (so the emoji the
    /// person tapped survives loading) and clears it once the loaded list no
    /// longer has that emoji.
    static func selection(_ selected: String?, availableEmojis: [String]?) -> String? {
        guard let selected, let availableEmojis else { return selected }
        return availableEmojis.contains(selected) ? selected : nil
    }
}

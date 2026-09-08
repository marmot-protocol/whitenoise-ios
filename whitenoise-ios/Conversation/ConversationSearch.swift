import Foundation
import Observation

/// One searchable timeline row: the row's timeline id, its message id, and the
/// budget-bounded plain-text haystack derived from the message body.
struct ConversationSearchEntry: Equatable {
    let itemId: String
    let messageIdHex: String
    let text: String
}

/// One query hit. Matches are kept in timeline order, oldest first.
struct ConversationSearchMatch: Equatable, Hashable {
    let itemId: String
    let messageIdHex: String
}

/// Pure match indexing and cursor arithmetic for in-conversation search.
/// Matching uses localized standard comparison, so it is case- and
/// diacritic-insensitive in the user's locale.
nonisolated enum ConversationSearchEngine {

    /// nil when the raw field text trims to nothing.
    static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func matches(
        for query: String,
        in entries: [ConversationSearchEntry]
    ) -> [ConversationSearchMatch] {
        guard let normalized = normalizedQuery(query) else { return [] }
        return entries.compactMap { entry in
            guard entry.text.localizedStandardContains(normalized) else { return nil }
            return ConversationSearchMatch(itemId: entry.itemId, messageIdHex: entry.messageIdHex)
        }
    }

    /// A fresh query lands on the newest match — the one closest to the live tail.
    static func initialIndex(matchCount: Int) -> Int? {
        matchCount > 0 ? matchCount - 1 : nil
    }

    /// Step toward older matches, wrapping from the oldest back to the newest.
    /// Without a cursor the step lands on the newest match.
    static func olderIndex(from current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let current, current > 0, current < matchCount else { return matchCount - 1 }
        return current - 1
    }

    /// Step toward newer matches, wrapping from the newest back to the oldest.
    /// Without a cursor the step lands on the newest match.
    static func newerIndex(from current: Int?, matchCount: Int) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let current, current >= 0 else { return matchCount - 1 }
        return current < matchCount - 1 ? current + 1 : 0
    }

    /// After the loaded window changes, find the cursor's row again by id.
    static func reanchoredIndex(of itemId: String?, in matches: [ConversationSearchMatch]) -> Int? {
        guard let itemId else { return nil }
        return matches.firstIndex { $0.itemId == itemId }
    }

    /// Counter position counted from the newest match, so the first jump reads 1.
    static func displayPosition(index: Int, matchCount: Int) -> Int {
        matchCount - index
    }
}

/// Budget for pulling older history into the loaded window during one search
/// step. Each page is one backward-pagination request through the live
/// timeline subscription, so a step scans at most `maxOlderPagesPerStep`
/// additional pages before surfacing the explicit "Search older messages"
/// continuation instead of scanning unboundedly.
nonisolated enum ConversationSearchPagingPolicy {
    static let maxOlderPagesPerStep = 3

    static func shouldLoadOlderPage(
        hasMoreBefore: Bool,
        pagesLoaded: Int,
        cap: Int = maxOlderPagesPerStep
    ) -> Bool {
        hasMoreBefore && pagesLoaded < cap
    }

    enum StepOutcome: Equatable {
        case foundOlderMatch
        case exhaustedHistory
        case cappedWithMoreHistory
    }

    static func stepOutcome(foundOlderMatch: Bool, hasMoreBefore: Bool) -> StepOutcome {
        if foundOlderMatch { return .foundOlderMatch }
        return hasMoreBefore ? .cappedWithMoreHistory : .exhaustedHistory
    }
}

/// Screen-scoped state for in-conversation message search: the query, the
/// ordered matches over the loaded window, the current-match cursor, and the
/// budgeted older-history paging step. Owned by `ConversationViewModel`; the
/// timeline inputs arrive through injected closures so this model holds no
/// store references of its own.
@Observable
@MainActor
final class ConversationSearchModel {

    /// A one-shot scroll-to-match request. The generation keeps repeated jumps
    /// to the same row distinguishable through `onChange`.
    struct ScrollRequest: Equatable {
        let itemId: String
        let generation: Int
    }

    private(set) var isActive = false
    private(set) var matches: [ConversationSearchMatch] = []
    private(set) var currentIndex: Int?
    private(set) var isPagingOlder = false
    private(set) var scrollRequest: ScrollRequest?

    var query = "" {
        didSet {
            guard isActive, query != oldValue else { return }
            recomputeForQueryChange()
        }
    }

    @ObservationIgnored var entriesProvider: () -> [ConversationSearchEntry] = { [] }
    @ObservationIgnored var hasMoreBefore: () -> Bool = { false }
    @ObservationIgnored var loadOlderPage: () async -> Void = {}

    @ObservationIgnored var analytics: ProductAnalyticsRecorder?
    @ObservationIgnored private var analyticsTicket: ProductAnalyticsRecorder.Ticket?
    @ObservationIgnored private var observedQuery = false
    @ObservationIgnored private var observedMatch = false
    @ObservationIgnored private var searchFailed = false

    @ObservationIgnored private var scrollGeneration = 0

    var currentMatch: ConversationSearchMatch? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    var hasQuery: Bool {
        ConversationSearchEngine.normalizedQuery(query) != nil
    }

    /// Counter position counted from the newest match (1 = newest), nil when
    /// there is no cursor.
    var displayPosition: Int? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return ConversationSearchEngine.displayPosition(index: currentIndex, matchCount: matches.count)
    }

    var canGoToOlderMatch: Bool {
        isActive && hasQuery && (!matches.isEmpty || hasMoreBefore())
    }

    var canGoToNewerMatch: Bool {
        isActive && !matches.isEmpty
    }

    /// Whether the "Search older messages" continuation should be offered:
    /// there is a query and history beyond the loaded window is still unsearched.
    var showsOlderContinuation: Bool {
        isActive && hasQuery && hasMoreBefore()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        analyticsTicket = analytics?.ticket()
        observedQuery = false
        observedMatch = false
        searchFailed = false
    }

    @discardableResult
    func end() -> Task<Void, Never>? {
        guard isActive else { return nil }
        let outcome: ProductSearchOutcome = searchFailed ? .failure : (observedMatch ? .success : (observedQuery ? .empty : .cancelled))
        let observation = analytics?.record(.search(outcome), ticket: analyticsTicket)
        analyticsTicket = nil
        isActive = false
        query = ""
        matches = []
        currentIndex = nil
        scrollRequest = nil
        isPagingOlder = false
        return observation
    }

    /// Recompute matches after any timeline/projection change, keeping the
    /// cursor on the same row when it still matches. Passive refreshes never
    /// request a scroll.
    func refreshAfterTimelineChange() {
        guard isActive, hasQuery else { return }
        let anchorId = currentMatch?.itemId
        matches = ConversationSearchEngine.matches(for: query, in: entriesProvider())
        currentIndex = ConversationSearchEngine.reanchoredIndex(of: anchorId, in: matches)
            ?? ConversationSearchEngine.initialIndex(matchCount: matches.count)
    }

    func goToNewerMatch() {
        guard isActive,
              let next = ConversationSearchEngine.newerIndex(from: currentIndex, matchCount: matches.count)
        else { return }
        currentIndex = next
        requestScrollToCurrentMatch()
    }

    func goToOlderMatch() async {
        guard isActive else { return }
        if let currentIndex, currentIndex > 0 {
            self.currentIndex = currentIndex - 1
            requestScrollToCurrentMatch()
            return
        }
        // At the oldest loaded match (or none loaded yet): pull older history
        // into the window within the paging budget before deciding to wrap.
        if hasMoreBefore() {
            await runOlderPagingStep(wrapIfExhausted: true)
        } else if let wrapped = ConversationSearchEngine.olderIndex(
            from: currentIndex,
            matchCount: matches.count
        ) {
            currentIndex = wrapped
            requestScrollToCurrentMatch()
        }
    }

    /// The explicit continuation after a capped step: one more budgeted step.
    func searchOlder() async {
        guard isActive, hasQuery, hasMoreBefore() else { return }
        await runOlderPagingStep(wrapIfExhausted: false)
    }

    func notePagingFailure() { if isActive { searchFailed = true } }

    private func recomputeForQueryChange() {
        observedQuery = observedQuery || hasQuery
        matches = ConversationSearchEngine.matches(for: query, in: entriesProvider())
        observedMatch = observedMatch || !matches.isEmpty
        currentIndex = ConversationSearchEngine.initialIndex(matchCount: matches.count)
        requestScrollToCurrentMatch()
    }

    private func requestScrollToCurrentMatch() {
        guard let match = currentMatch else { return }
        observedMatch = true
        scrollGeneration += 1
        scrollRequest = ScrollRequest(itemId: match.itemId, generation: scrollGeneration)
    }

    private func runOlderPagingStep(wrapIfExhausted: Bool) async {
        guard !isPagingOlder, hasQuery else { return }
        let steppedQuery = query
        let anchorId = currentMatch?.itemId
        isPagingOlder = true
        defer { isPagingOlder = false }

        var pagesLoaded = 0
        var foundOlderMatch = false
        while ConversationSearchPagingPolicy.shouldLoadOlderPage(
            hasMoreBefore: hasMoreBefore(),
            pagesLoaded: pagesLoaded
        ) {
            await loadOlderPage()
            guard isActive, query == steppedQuery else { return }
            pagesLoaded += 1
            refreshAfterTimelineChange()
            foundOlderMatch = hasMatchOlder(thanAnchor: anchorId)
            if foundOlderMatch { break }
        }

        switch ConversationSearchPagingPolicy.stepOutcome(
            foundOlderMatch: foundOlderMatch,
            hasMoreBefore: hasMoreBefore()
        ) {
        case .foundOlderMatch:
            if let anchorIndex = ConversationSearchEngine.reanchoredIndex(of: anchorId, in: matches),
               anchorIndex > 0 {
                currentIndex = anchorIndex - 1
            } else {
                currentIndex = ConversationSearchEngine.initialIndex(matchCount: matches.count)
            }
            requestScrollToCurrentMatch()
        case .exhaustedHistory:
            guard wrapIfExhausted,
                  let wrapped = ConversationSearchEngine.olderIndex(
                    from: currentIndex,
                    matchCount: matches.count
                  )
            else { return }
            currentIndex = wrapped
            requestScrollToCurrentMatch()
        case .cappedWithMoreHistory:
            // Budget spent without a hit, the continuation row stays offered.
            break
        }
    }

    private func hasMatchOlder(thanAnchor anchorId: String?) -> Bool {
        guard let anchorId else { return !matches.isEmpty }
        guard let anchorIndex = ConversationSearchEngine.reanchoredIndex(of: anchorId, in: matches) else {
            // The anchor row left the window (deleted or evicted), any hit counts.
            return !matches.isEmpty
        }
        return anchorIndex > 0
    }
}

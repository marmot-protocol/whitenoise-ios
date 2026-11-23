import SwiftUI

/// Search entry pinned under the conversation header. Result navigation lives
/// in `ConversationSearchControls`, where the composer normally sits.
struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchModel
    let onClose: () -> Void

    var body: some View {
        WNSearchBar(query: $search.query, prompt: "Search messages",
                    dismissesKeyboardOnSubmit: false, onClose: onClose)
            .task(id: search.nextPollDeadline) {
                guard let deadline = search.nextPollDeadline else { return }
                // MDK deadlines are unsigned timestamps and may exceed the range of a Duration.
                while deadline.timeIntervalSinceNow > 0 {
                    do { try await Task.sleep(for: .seconds(min(deadline.timeIntervalSinceNow, 86_400))) }
                    catch { return }
                }
                guard !Task.isCancelled, search.nextPollDeadline == deadline else { return }
                search.refreshAfterSearchableContentChange()
            }
    }
}

struct ConversationSearchControls: View {
    @Bindable var search: ConversationSearchModel
    let oversizedResultID: String?

    @ScaledMetric(relativeTo: .body) private var controlSize = WNSearchBar.Metrics.fieldHeight

    var body: some View {
        VStack(spacing: 4) {
            if let match = search.currentMatch, match.itemId == oversizedResultID,
               let excerpt = ConversationSearchEngine.excerpt(in: match.matchingText, matching: search.query, leadingContext: 6) {
                TimelineSearchText(excerpt)
                    .environment(\.timelineSearchQuery, ConversationSearchEngine.normalizedQuery(search.query))
                    .font(.footnote)
                    .lineLimit(1)
            }
            ZStack {
                HStack(spacing: 0) {
                    searchButton(
                        systemImage: "chevron.up",
                        accessibilityLabel: "Previous match",
                        disabled: !search.canGoToOlderMatch || search.isPagingOlder
                    ) {
                        Task { await search.goToOlderMatch() }
                    }
                    searchButton(
                        systemImage: "chevron.down",
                        accessibilityLabel: "Next match",
                        disabled: !search.canGoToNewerMatch || search.isPagingOlder
                    ) {
                        search.goToNewerMatch()
                    }
                }
                .compatibleInputCapsuleChrome(interactive: false)
                .frame(maxWidth: .infinity, alignment: .leading)

                if search.hasQuery {
                    let buttonInset = 2 * controlSize + WNSearchBar.Metrics.rowSpacing
                    ViewThatFits(in: .horizontal) {
                        resultCountCapsule.fixedSize().padding(.horizontal, buttonInset)
                        resultCountCapsule.padding(.leading, buttonInset)
                    }
                    .allowsHitTesting(false)
                }
            }

            if search.showsOlderContinuation {
                olderContinuationRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var resultCount: some View {
        if let position = search.displayPosition {
            Text(L10n.formatted("%1$lld of %2$lld", Int64(position), Int64(search.matches.count)))
                .contentTransition(.numericText())
        } else {
            Text(L10n.string("No matches"))
        }
    }

    private var resultCountCapsule: some View {
        resultCount
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .frame(minHeight: controlSize)
            .compatibleInputCapsuleChrome(interactive: false)
    }

    private func searchButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: controlSize, height: controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var olderContinuationRow: some View {
        Button {
            Task { await search.searchOlder() }
        } label: {
            HStack(spacing: 6) {
                if search.isPagingOlder {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(L10n.string("Search older messages"))
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(search.isPagingOlder)
    }
}

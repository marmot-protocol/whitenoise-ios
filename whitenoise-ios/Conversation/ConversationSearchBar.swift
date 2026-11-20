import SwiftUI

/// Search entry pinned under the conversation header. Result navigation lives
/// in `ConversationSearchControls`, where the composer normally sits.
struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchModel
    let onClose: () -> Void
    @State private var deadlineTimer: Timer?

    var body: some View {
        WNSearchBar(query: $search.query, prompt: "Search messages",
                    dismissesKeyboardOnSubmit: false, onClose: onClose)
            .onChange(of: search.nextPollDeadline, initial: true) { _, deadline in
                deadlineTimer?.invalidate()
                deadlineTimer = nil
                guard let deadline else { return }
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak search = self.search] _ in
                    // Installed on the main run loop, including while the transcript scrolls.
                    MainActor.assumeIsolated {
                        guard let search, search.nextPollDeadline == deadline else { return }
                        search.refreshAfterPollDeadline()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                deadlineTimer = timer
            }
            .onDisappear {
                deadlineTimer?.invalidate()
                deadlineTimer = nil
            }
    }
}

struct ConversationSearchControls: View {
    @Bindable var search: ConversationSearchModel

    @ScaledMetric(relativeTo: .body) private var controlSize = WNSearchBar.Metrics.fieldHeight

    var body: some View {
        VStack(spacing: 4) {
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

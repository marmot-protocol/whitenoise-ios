import SwiftUI

/// Search entry pinned under the conversation header. Result navigation lives
/// in `ConversationSearchControls`, where the composer normally sits.
struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchModel
    let onClose: () -> Void

    var body: some View {
        WNSearchBar(query: $search.query, prompt: "Search messages",
                    dismissesKeyboardOnSubmit: false, onClose: onClose)
    }
}

struct ConversationSearchControls: View {
    @Bindable var search: ConversationSearchModel

    @ScaledMetric(relativeTo: .body) private var controlSize = WNSearchBar.Metrics.fieldHeight

    var body: some View {
        VStack(spacing: 4) {
            HStack {
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

                Spacer(minLength: 8)

                if search.hasQuery {
                    resultCount
                        .padding(.horizontal, 18)
                        .frame(minHeight: controlSize)
                        .compatibleInputCapsuleChrome(interactive: false)
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

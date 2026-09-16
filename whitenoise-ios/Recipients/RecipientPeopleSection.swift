import SwiftUI

/// The people list shared by New Message, the group picker, and Add Members.
/// Every screen shows the same loading row, load-failure row, and empty
/// states; only the row content and the empty-state sentence differ.
struct RecipientPeopleSection<Row: View>: View {
    let state: RecipientBrowseState
    let candidates: [RecipientCandidate]
    /// Shown only while browsing, so search results stay unlabelled.
    var header: LocalizedStringKey?
    var emptyTitle: LocalizedStringKey = "No people yet"
    /// Opt-in per screen: rounding one section and leaving its neighbours
    /// system-drawn reads worse than leaving the whole screen alone, so a
    /// screen takes this only once every section it shows is rounded too.
    var roundsSectionCard = false
    let emptyDescription: LocalizedStringKey
    let onRetryLoad: () -> Void
    @ViewBuilder let row: (RecipientCandidate) -> Row

    var body: some View {
        switch state {
        case .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 16)
            }
        case .loadFailed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetryLoad)
            }
        case .awaitingSearch:
            EmptyView()
        case .noPeople:
            Section {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "person.2")
                } description: {
                    Text(emptyDescription)
                }
                .wnInputRow()
            }
        case .noMatches(let query):
            Section {
                ContentUnavailableView.search(text: query)
                    .wnInputRow()
            }
        case .people:
            Section {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if roundsSectionCard {
                        row(candidate)
                            .wnGroupedCardRow(.at(index, of: candidates.count))
                    } else {
                        row(candidate)
                    }
                }
            } header: {
                if let header {
                    Text(header)
                }
            }
        }
    }
}

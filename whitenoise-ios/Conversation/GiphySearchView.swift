import SwiftUI

struct GiphySearchView: View {
    let client: GiphySearchClient
    let onSelect: (GiphySearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GiphySearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("Your search and IP address are sent to GIPHY. Opening a received GIF also contacts GIPHY.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    resultContent

                    PoweredByGiphyMark()
                        .padding(.vertical, 10)
                }
                .padding(.horizontal, 12)
            }
            .navigationTitle(L10n.string("GIFs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: L10n.string("Search GIPHY"))
            .task(id: query) { await searchAfterDebounce() }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if isLoading && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if let errorMessage {
            ContentUnavailableView(
                L10n.string("Couldn't search GIFs"),
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(errorMessage)
            )
            .frame(minHeight: 220)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                L10n.string("Search GIPHY"),
                systemImage: "magnifyingglass",
                description: Text(L10n.string("Find a GIF to send to this conversation."))
            )
            .frame(minHeight: 220)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(minHeight: 220)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(results) { result in
                    Button {
                        onSelect(result)
                        dismiss()
                    } label: {
                        GiphySearchResultTile(result: result)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(result.title)
                }
            }
        }
    }

    private func searchAfterDebounce() async {
        let issuedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issuedQuery.isEmpty else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            isLoading = true
            errorMessage = nil
            let fetched = try await client.search(issuedQuery)
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == issuedQuery else { return }
            results = fetched
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            isLoading = false
            errorMessage = UserFacingError.message(for: error)
        }
    }
}

private struct GiphySearchResultTile: View {
    let result: GiphySearchResult

    var body: some View {
        ZStack {
            GiphySearchPreviewView(media: result.media)

            if let attribution = result.media.attribution {
                Text(attribution)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .aspectRatio(result.media.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }
}

struct PoweredByGiphyMark: View {
    var body: some View {
        HStack(spacing: 7) {
            Text("Powered by")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image("GiphyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 22)
                .accessibilityLabel(L10n.string("GIPHY"))
        }
        .accessibilityElement(children: .combine)
    }
}

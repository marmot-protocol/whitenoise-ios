import SwiftUI

struct OnboardingAvatarWebImagePicker: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case search
        case url

        var id: Self { self }
        var title: LocalizedStringKey { self == .search ? "Search" : "URL" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.search
    @State private var query = ""
    @State private var imageURL = ""
    @State private var results: [GroupImageSearchResult] = []
    @State private var selectedURL: URL?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var cropURL: URL?
    @State private var cropSource: AvatarImageCropSource?
    @FocusState private var isURLFocused: Bool

    let onCrop: (AvatarImageCropSource, Data) -> Void
    let onError: (Error) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 1),
        count: 3
    )

    var body: some View {
        NavigationStack {
            modeContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }

                    ToolbarItem(placement: .principal) {
                        Picker("Image Source", selection: $mode) {
                            ForEach(Mode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.palette)
                        .frame(width: 180)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            guard let activeURL else { return }
                            cropSource = nil
                            cropURL = activeURL
                        }
                        .disabled(activeURL == nil)
                    }
                }
                .onChange(of: mode) {
                    if mode == .url, imageURL.isEmpty, let selectedURL {
                        imageURL = selectedURL.absoluteString
                    }
                    isURLFocused = mode == .url
                }
                .navigationDestination(item: $cropURL) { _ in
                    AvatarImageCropEditor(
                        source: cropSource,
                        onClose: { dismiss() },
                        onCrop: onCrop
                    )
                }
        }
        .task(id: cropURL) {
            await loadCropSource(cropURL)
        }
    }

    private func loadCropSource(_ url: URL?) async {
        guard let url else { return }
        do {
            let data = try await RemoteImageFetch.imageData(for: url)
            try Task.checkCancellation()
            cropSource = AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            )
        } catch {
            guard !Task.isCancelled else { return }
            onError(error)
            dismiss()
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .search:
            searchContent
        case .url:
            urlContent
        }
    }

    private var searchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchCard {
                    privacyDisclosure(
                        title: "Search privacy",
                        detail: "Your search is sent to DuckDuckGo. Image providers can see your IP address when results load."
                    )
                }

                searchCard {
                    WNSearchField(query: $query, prompt: "Search Images")
                }

                if isSearching {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 28)
                } else if let searchError {
                    searchCard {
                        Label(searchError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else if normalizedQuery.isEmpty {
                    searchCard {
                        ContentUnavailableView(
                            "Search Images",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("Enter a search to find an image.")
                        )
                        .frame(maxWidth: .infinity)
                    }
                } else if !results.isEmpty {
                    // Keep async thumbnails out of Form rows; iOS 26 can recurse during collection self-sizing.
                    LazyVGrid(columns: columns, spacing: 1) {
                        ForEach(results) { result in
                            resultButton(result)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .task(id: normalizedQuery) {
            await searchAfterDebounce()
        }
    }

    private var urlContent: some View {
        Form {
            Section {
                privacyDisclosure(
                    title: "Image privacy",
                    detail: "The image provider can see your IP address when the preview loads."
                )
            }

            Section("Image URL") {
                TextField("https://example.com/image.jpg", text: $imageURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isURLFocused)

                if imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter an image URL to preview it below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let url = validatedURL {
                    GroupImageRemoteThumbnail(url: url)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .clipped()
                } else {
                    Text("Enter a valid web address.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        ContentSanitizer.imageURL(
            imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var activeURL: URL? {
        mode == .search ? selectedURL : validatedURL
    }

    private func searchAfterDebounce() async {
        guard !normalizedQuery.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            let issuedQuery = normalizedQuery
            isSearching = true
            searchError = nil
            let fetched = try await DuckDuckGoImageSearchClient().search(issuedQuery)
            try Task.checkCancellation()
            guard issuedQuery == normalizedQuery else { return }
            results = fetched
            if fetched.isEmpty {
                searchError = L10n.string("No usable HTTPS images found.")
            }
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            isSearching = false
            searchError = UserFacingError.message(for: error)
        }
    }

    private func resultButton(_ result: GroupImageSearchResult) -> some View {
        Button {
            selectedURL = result.imageURL
        } label: {
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GroupImageRemoteThumbnail(url: result.thumbnailURL ?? result.imageURL)
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if selectedURL == result.imageURL {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(WNNeutralAccent.foreground)
                            .padding(5)
                            .background(Color.accentColor, in: .circle)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .padding(6)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.title.isEmpty ? "Image result" : result.title)
        .accessibilityAddTraits(selectedURL == result.imageURL ? .isSelected : [])
    }

    private func searchCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 12)
            )
    }

    private func privacyDisclosure(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

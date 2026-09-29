import SwiftUI

struct OnboardingAvatarWebImagePicker: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case search
        case url

        var id: Self { self }
        var title: LocalizedStringKey { self == .search ? "Search" : "URL" }
    }

    private struct SearchRequest: Equatable {
        let query: String
        let retry: Int
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.search
    @State private var query = ""
    @State private var imageURL = ""
    @State private var resultRows: [[GroupImageSearchResult]] = []
    @State private var isSearchFocused = false
    @State private var searchRetry = 0
    @State private var selectedURL: URL?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var download = OnboardingImageDownloadModel()
    @State private var urlPreview: (url: URL, image: UIImage)?
    @State private var loadingPreviewURL: URL?
    @State private var previewFailure: (url: URL, message: String)?
    @FocusState private var isURLFocused: Bool

    let onCrop: (AvatarImageCropSource, Data) async throws -> Void

    var body: some View {
        NavigationStack {
            modeContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            download.cancel()
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
                        .controlSize(.extraLarge)
                        .frame(width: 180)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            guard let activeURL, download.request == nil else { return }
                            isSearchFocused = false
                            isURLFocused = false
                            download.start(activeURL)
                        } label: {
                            Text("Done")
                                .opacity(download.request == nil ? 1 : 0)
                                .overlay {
                                    if download.request != nil { ProgressView() }
                                }
                        }
                        .accessibilityLabel(download.request == nil ? L10n.string("Done") : L10n.string("Downloading"))
                        .disabled(activeURL == nil || download.request != nil)
                    }
                }
                .onChange(of: mode) {
                    download.cancel()
                    isSearchFocused = false
                    if mode == .url, imageURL.isEmpty, let selectedURL {
                        imageURL = selectedURL.absoluteString
                    }
                    isURLFocused = mode == .url
                }
                .navigationDestination(item: $download.source) { source in
                    AvatarImageCropEditor(
                        source: source,
                        onClose: { dismiss() },
                        onChooseAnother: { download.source = nil },
                        onCrop: onCrop
                    )
                }
        }
        .photoSelectionFailureAlert(
            $download.failure,
            retry: { download.retry() },
            dismissTitle: "Back",
            chooseAnother: nil
        )
        .task(id: download.request?.id) {
            guard let request = download.request else { return }
            await download.load(request)
        }
        .onChange(of: selectedURL) { download.cancel() }
        .onChange(of: imageURL) { download.cancel() }
        .onDisappear { download.cancel() }
        .overlay {
            OnboardingImageKeyboardBackdrop()
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
        searchViewport
            .modifier(OnboardingImageSearchInset {
                HStack(spacing: isSearchFocused ? 4 : nil) {
                    OnboardingImageSearchBar(text: $query, isFocused: $isSearchFocused)
                        .frame(maxWidth: .infinity)
                    if isSearchFocused {
                        Button { isSearchFocused = false } label: { Image(systemName: "xmark") }
                            .compatibleGlassCircleButtonStyle()
                            .controlSize(.extraLarge)
                            .accessibilityLabel("Dismiss Keyboard")
                    }
                }
                .safeAreaPadding(.leading, isSearchFocused ? 0 : nil)
                .safeAreaPadding(.trailing, isSearchFocused ? 8 : nil)
            })
            .task(id: SearchRequest(query: normalizedQuery, retry: searchRetry)) { await searchAfterDebounce() }
    }

    @ViewBuilder
    private var searchViewport: some View {
        if normalizedQuery.isEmpty || isSearching || searchError != nil || resultRows.isEmpty {
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 24) {
                        searchPrivacyDisclosure
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                        Spacer(minLength: 0)
                        searchStatus
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        } else {
            searchResultsForm
        }
    }

    private var searchPrivacyDisclosure: some View {
        privacyDisclosure(
            title: "Search privacy",
            detail: "Your search is sent to DuckDuckGo. Image providers can see your IP address when results load."
        )
    }

    private var searchResultsForm: some View {
        Form {
            Section { searchPrivacyDisclosure }
            Section {
                ForEach(resultRows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 1) {
                        ForEach(resultRows[rowIndex]) { result in resultButton(result) }
                        ForEach(0..<(3 - resultRows[rowIndex].count), id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 1, trailing: 0))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var searchStatus: some View {
        if normalizedQuery.isEmpty {
            ContentUnavailableView(
                "Search Images", systemImage: "photo.on.rectangle.angled",
                description: Text("Enter a search to find an image.")
            )
        } else if isSearching {
            ProgressView()
        } else if let searchError {
            ContentUnavailableView {
                Label("Couldn’t Search Images", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(searchError)
            } actions: {
                Button("Retry") { searchRetry += 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView.search(text: normalizedQuery)
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
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Image URL")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, WNInputMetrics.leadingInset)
                    WNInput(
                        placeholder: "https://example.com/image.jpg",
                        text: $imageURL,
                        surface: .filled,
                        showsTextFromBeginning: true,
                        focus: $isURLFocused
                    )
                    .accessibilityLabel("Image URL")
                    .textContentType(.URL)
                    .keyboardType(.URL)

                    if !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validatedURL == nil {
                        Text("Enter a valid web address.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, WNInputMetrics.leadingInset)
                    } else if let previewFailure, previewFailure.url == validatedURL {
                        Text(previewFailure.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, WNInputMetrics.leadingInset)
                    }
                }
                .wnInputRow()
            }
            if loadedURLPreview != nil || isLoadingURLPreview {
                Section {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if let image = loadedURLPreview {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                ProgressView("Loading image")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .clipShape(.rect(cornerRadius: WNGroupedCardMetrics.cornerRadius, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .wnGroupedCardRow(.only)
                } header: {
                    Text("Preview").wnSectionHeader()
                }
            }
        }
        .formStyle(.grouped)
        .scrollDismissesKeyboard(.interactively)
        .task(id: validatedURL) { await loadURLPreview() }
    }

    private var isLoadingURLPreview: Bool {
        guard let loadingPreviewURL else { return false }
        return loadingPreviewURL == validatedURL
    }

    private var loadedURLPreview: UIImage? {
        guard let urlPreview, urlPreview.url == validatedURL else { return nil }
        return urlPreview.image
    }

    private func loadURLPreview() async {
        urlPreview = nil
        previewFailure = nil
        loadingPreviewURL = validatedURL
        guard let url = validatedURL else { return }
        defer {
            if !Task.isCancelled, loadingPreviewURL == url { loadingPreviewURL = nil }
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let source = try await AvatarImageCropSource.downloaded(from: url)
            try Task.checkCancellation()
            guard url == validatedURL, let image = source.preparedImage else { return }
            urlPreview = (url, image)
        } catch {
            guard !Task.isCancelled, url == validatedURL else { return }
            previewFailure = (url, PhotoSelectionFailure.classify(error, fallback: .download).message)
        }
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
            resultRows = []
            searchError = nil
            isSearching = false
            return
        }
        let issuedQuery = normalizedQuery
        do {
            try await Task.sleep(for: .milliseconds(350))
            try Task.checkCancellation()
            isSearching = true
            searchError = nil
            let fetched = try await DuckDuckGoImageSearchClient().search(issuedQuery)
            try Task.checkCancellation()
            guard issuedQuery == normalizedQuery else { return }
            resultRows = stride(from: 0, to: fetched.count, by: 3).map {
                Array(fetched[$0..<min($0 + 3, fetched.count)])
            }
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, issuedQuery == normalizedQuery else { return }
            isSearching = false
            searchError = PhotoSelectionFailure.classify(error) == .connection
                ? L10n.string("Please check your connection and try again.")
                : L10n.string("Image search is temporarily unavailable.")
        }
    }

    private func resultButton(_ result: GroupImageSearchResult) -> some View {
        Button {
            selectedURL = result.imageURL
            imageURL = result.imageURL.absoluteString
            isSearchFocused = false
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

    private func privacyDisclosure(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingImageSearchInset<Bar: View>: ViewModifier {
    @ViewBuilder var bar: () -> Bar

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, content: bar)
        } else {
            content.safeAreaInset(edge: .bottom, content: bar)
        }
    }
}

import Foundation
import MarmotKit
import PhotosUI
import SwiftUI
import UIKit

struct GroupImageSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let imageURL: URL
    let thumbnailURL: URL?
    let sourceHost: String?
    let dimensionsLabel: String?
}

struct DuckDuckGoImageSearchClient {
    private static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " +
        "Mobile/15E148 Safari/604.1"

    func search(_ rawQuery: String) async throws -> [GroupImageSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw DuckDuckGoImageSearchError.emptyQuery }

        var landing = URLComponents(string: "https://duckduckgo.com/")!
        landing.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iax", value: "images"),
            URLQueryItem(name: "ia", value: "images")
        ]

        let landingData = try await data(for: landing.url!)
        guard let landingHTML = String(data: landingData, encoding: .utf8),
              let token = Self.vqdToken(in: landingHTML)
        else { throw DuckDuckGoImageSearchError.missingToken }

        var api = URLComponents(string: "https://duckduckgo.com/i.js")!
        api.queryItems = [
            URLQueryItem(name: "l", value: "us-en"),
            URLQueryItem(name: "o", value: "json"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vqd", value: token),
            URLQueryItem(name: "p", value: "1")
        ]

        let resultsData = try await data(
            for: api.url!,
            referer: URL(string: "https://duckduckgo.com/")!
        )
        return try Self.decodeResults(from: resultsData)
    }

    static func vqdToken(in html: String) -> String? {
        let patterns = [
            #"vqd\s*[:=]\s*['"]([^'"]+)['"]"#,
            #""vqd"\s*:\s*"([^"]+)""#,
            #"vqd=([^&"'\\]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: html)
            else { continue }
            return String(html[tokenRange]).replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    /// Upper bound on the number of search results parsed and rendered. The
    /// DuckDuckGo response is third-party and unbounded, so cap the raw entries
    /// before dedup/sanitization to keep in-memory result count — and the
    /// outbound thumbnail fetches the grid drives as the user scrolls — bounded
    /// regardless of what the search backend returns.
    static let maximumResultCount = 60

    /// Bound and sanitize untrusted result titles before they are rendered as a
    /// fallback when DuckDuckGo's source URL cannot be displayed.
    static let maximumResultTitleLength = 120

    static func decodeResults(from data: Data) throws -> [GroupImageSearchResult] {
        let response = try JSONDecoder().decode(DuckDuckGoImageResponse.self, from: data)
        var seen = Set<String>()
        return response.results.prefix(maximumResultCount).compactMap { raw in
            guard let imageURL = sanitizedImageURL(raw.image) else { return nil }
            guard seen.insert(imageURL.absoluteString).inserted else { return nil }
            let thumbnailURL = sanitizedImageURL(raw.thumbnail)
            return GroupImageSearchResult(
                id: imageURL.absoluteString,
                title: ContentSanitizer.compactSingleLine(raw.title, maxLength: maximumResultTitleLength) ?? "",
                imageURL: imageURL,
                thumbnailURL: thumbnailURL,
                sourceHost: sourceHost(for: raw.sourceURL ?? raw.image),
                dimensionsLabel: dimensionsLabel(width: raw.width, height: raw.height)
            )
        }
    }

    static func sanitizedImageURL(_ raw: String?) -> URL? {
        guard var candidate = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else { return nil }
        if candidate.hasPrefix("//") {
            candidate = "https:" + candidate
        }
        return ContentSanitizer.imageURL(candidate)
    }

    static func request(for url: URL, referer: URL? = nil) -> URLRequest {
        var request = RemoteImageFetch.request(
            for: url,
            accept: "application/json,text/html;q=0.9,*/*;q=0.8"
        )
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private func data(for url: URL, referer: URL? = nil) async throws -> Data {
        do {
            let (data, response) = try await RemoteImageFetch.data(
                for: Self.request(for: url, referer: referer)
            )
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else { throw DuckDuckGoImageSearchError.badResponse }
            return data
        } catch let error as URLError where error.code == .badServerResponse {
            throw DuckDuckGoImageSearchError.badResponse
        }
    }

    private static func sourceHost(for raw: String?) -> String? {
        sanitizedImageURL(raw)?.host
    }

    static func dimensionsLabel(
        width: Int?,
        height: Int?,
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return L10n.formatted(
            "%@ × %@",
            arguments: [
                LocalizedNumberLabel.decimal(UInt64(width), locale: locale),
                LocalizedNumberLabel.decimal(UInt64(height), locale: locale)
            ],
            locale: locale
        )
    }
}

private struct DuckDuckGoImageResponse: Decodable {
    let results: [DuckDuckGoImageResult]
}

private struct DuckDuckGoImageResult: Decodable {
    let title: String?
    let image: String
    let thumbnail: String?
    let sourceURL: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case image
        case thumbnail
        case sourceURL = "url"
        case width
        case height
    }
}

enum DuckDuckGoImageSearchError: LocalizedError {
    case emptyQuery
    case missingToken
    case badResponse

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return L10n.string("Enter a search term.")
        case .missingToken:
            return L10n.string("Image search is temporarily unavailable.")
        case .badResponse:
            return L10n.string("Image search returned an unexpected response.")
        }
    }
}


nonisolated struct GroupImageUploadDraft: Equatable {
    let data: Data
    let mediaType: String
    let sourceURL: String?
    let dim: String?
    let thumbhash: String?
    let thumbnail: UIImage?

    init(
        data: Data,
        mediaType: String,
        sourceURL: String?,
        dim: String?,
        thumbhash: String?,
        thumbnail: UIImage? = nil
    ) {
        self.data = data
        self.mediaType = mediaType
        self.sourceURL = sourceURL
        self.dim = dim
        self.thumbhash = thumbhash
        self.thumbnail = thumbnail
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data
            && lhs.mediaType == rhs.mediaType
            && lhs.sourceURL == rhs.sourceURL
            && lhs.dim == rhs.dim
            && lhs.thumbhash == rhs.thumbhash
    }

    var initialImage: InitialGroupImageFfi {
        InitialGroupImageFfi(
            plaintext: data,
            mediaType: mediaType,
            // Do not publish the web origin as the legacy URL-avatar fallback.
            // The selected bytes must use the encrypted group-image component.
            sourceUrl: nil,
            dim: dim,
            thumbhash: thumbhash
        )
    }
}

enum GroupImageDraftProcessor {
    static func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String? = nil,
        sourceURL: URL? = nil
    ) async throws -> GroupImageUploadDraft {
        let attachment = try await MediaDraftProcessor.preparedAttachment(
            from: data,
            fileName: fileName,
            typeIdentifier: typeIdentifier
        )
        return try uploadDraft(from: attachment, sourceURL: sourceURL)
    }

    static func prepare(fileURL: URL) async throws -> GroupImageUploadDraft {
        let attachment = try await MediaDraftProcessor.preparedAttachment(fromFileURL: fileURL)
        return try uploadDraft(from: attachment, sourceURL: nil)
    }

    private static func uploadDraft(
        from attachment: MediaDraftAttachment,
        sourceURL: URL?
    ) throws -> GroupImageUploadDraft {
        guard attachment.kind == .image else {
            throw MediaDraftProcessor.Failure.unsupportedImage
        }
        return GroupImageUploadDraft(
            data: attachment.data,
            mediaType: attachment.mediaType,
            sourceURL: sourceURL?.absoluteString,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            thumbnail: attachment.thumbnail
        )
    }
}

enum GroupImageProgressPhase: Equatable {
    case preparing
    case updating
    case finishing

    var label: String {
        switch self {
        case .preparing:
            L10n.string("Preparing image…")
        case .updating:
            L10n.string("Updating group image…")
        case .finishing:
            L10n.string("Finishing update…")
        }
    }
}

/// Reference box for the save callback — the same toolchain hazard
/// `GroupRetentionSubmitter` works around: an async closure stored in a view
/// struct garbles its argument in debug builds, which crashed the save path.
@MainActor
final class GroupImageSaveSubmitter {
    typealias ProgressHandler = @MainActor (GroupImageProgressPhase?) -> Void

    private let run: (GroupImageUploadDraft?, ProgressHandler) async throws -> Void

    init(_ run: @escaping (GroupImageUploadDraft?) async throws -> Void) {
        self.run = { draft, _ in
            try await run(draft)
        }
    }

    init(
        progressReporting run: @escaping (
            GroupImageUploadDraft?,
            ProgressHandler
        ) async throws -> Void
    ) {
        self.run = run
    }

    func save(
        _ draft: GroupImageUploadDraft?,
        onProgress: @escaping ProgressHandler
    ) async throws {
        try await run(draft, onProgress)
    }
}

struct GroupImageURLSheet: View {
    @Environment(\.dismiss) private var dismiss

    let hasCurrentImage: Bool
    let currentURL: URL?
    let currentGroupIdHex: String?
    let currentImageHashHex: String?
    var searchClient = DuckDuckGoImageSearchClient()
    let onSave: GroupImageSaveSubmitter

    @State private var draft: GroupImageUploadDraft?
    @State private var searchQuery = ""
    @State private var searchResults: [GroupImageSearchResult] = []
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var isSearching = false
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var showPhotoPicker = false
    @State private var cropRequest: GroupImageCropRequest?
    @State private var webImageLoad: Task<Void, Never>?
    @State private var progressPhase: GroupImageProgressPhase?

    private let resultColumns = [
        GridItem(.adaptive(minimum: 108), spacing: 12)
    ]

    init(
        hasCurrentImage: Bool,
        currentURL: URL?,
        currentGroupIdHex: String? = nil,
        currentImageHashHex: String? = nil,
        initialDraft: GroupImageUploadDraft? = nil,
        searchClient: DuckDuckGoImageSearchClient = DuckDuckGoImageSearchClient(),
        onSave: GroupImageSaveSubmitter
    ) {
        self.hasCurrentImage = hasCurrentImage
        self.currentURL = currentURL
        self.currentGroupIdHex = currentGroupIdHex
        self.currentImageHashHex = currentImageHashHex
        self.searchClient = searchClient
        self.onSave = onSave
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        NavigationStack {
            Form {
                previewSection
                deviceSection
                searchSection

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Group image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveDraft() }
                    }
                    .disabled(draft == nil || isBusy)
                }
            }
            .navigationDestination(isPresented: isCropping) {
                AvatarImageCropEditor(source: cropRequest?.source, onCrop: prepareCroppedImage)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showPhotoPicker) {
            WNPhotoLibraryCropFlow(
                onCrop: prepareCroppedImage,
                onError: { error in
                    saveError = UserFacingError.message(for: error)
                    Haptics.error()
                },
                onClose: { showPhotoPicker = false }
            )
        }
    }

    private var isCropping: Binding<Bool> {
        Binding(
            get: { cropRequest != nil },
            set: { isPresented in
                guard !isPresented else { return }
                cancelWebImageLoad()
                cropRequest = nil
            }
        )
    }

    private func prepareCroppedImage(_ source: AvatarImageCropSource, _ croppedData: Data) {
        isPreparing = true
        progressPhase = .preparing
        Task {
            await prepare(
                data: croppedData,
                fileName: source.fileName,
                typeIdentifier: "public.jpeg",
                sourceURL: source.sourceURL
            )
        }
    }

    private var previewSection: some View {
        Section {
            HStack(spacing: 16) {
                VStack(spacing: 6) {
                    previewAvatar
                        .overlay {
                            if progressPhase != nil {
                                ZStack {
                                    Circle()
                                        .fill(.ultraThinMaterial)
                                        .frame(width: 38, height: 38)
                                    ProgressView()
                                        .controlSize(.regular)
                                }
                                .transition(.opacity.combined(with: .scale))
                            }
                        }

                    if let progressPhase {
                        Text(progressPhase.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 132)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: progressPhase)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Group image")
                        .font(.headline)
                        .lineLimit(1)
                    Text("End-to-end encrypted group messaging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var previewAvatar: some View {
        if let draft {
            AvatarBubble(
                seed: "group-image-preview",
                title: "Group",
                pictureImage: draft.thumbnail
            )
            .frame(width: 72, height: 72)
        } else if let currentGroupIdHex {
            GroupAvatarBubble(
                groupIdHex: currentGroupIdHex,
                imageHashHex: currentImageHashHex,
                seed: currentGroupIdHex,
                title: "Group",
                pictureURL: currentURL
            )
            .frame(width: 72, height: 72)
        } else {
            AvatarBubble(
                seed: "group-image-preview",
                title: "Group",
                pictureURL: currentURL
            )
            .frame(width: 72, height: 72)
        }
    }

    private var deviceSection: some View {
        Section {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            .disabled(isBusy)

            if hasCurrentImage {
                Button(role: .destructive) {
                    Task { await removeImage() }
                } label: {
                    Label("Remove image", systemImage: "trash")
                }
                .disabled(isBusy)
            }
        } header: {
            Text("Photos")
        }
    }

    private var searchSection: some View {
        Section("Search the web") {
            HStack(spacing: 8) {
                TextField("Image search", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .disabled(isBusy)
                    .onSubmit { startSearch() }

                Button {
                    startSearch()
                } label: {
                    if isSearching || isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .wnIconButtonChrome()
                .disabled(searchButtonDisabled)
                .accessibilityLabel("Search the web")
            }

            Label(
                L10n.string("Web search sends your query and IP address to DuckDuckGo and image hosts."),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !searchResults.isEmpty {
                LazyVGrid(columns: resultColumns, spacing: 12) {
                    ForEach(searchResults) { result in
                        Button {
                            prepareSearchResult(result)
                        } label: {
                            GroupImageResultCell(
                                result: result,
                                isSelected: result.imageURL.absoluteString == draft?.sourceURL
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var isBusy: Bool {
        isSearching || isPreparing || isSaving
    }

    private var searchButtonDisabled: Bool {
        Self.preparedSearchQuery(
            searchQuery,
            isSearching: isSearching,
            isSaving: isPreparing || isSaving
        ) == nil
    }

    static func preparedSearchQuery(
        _ rawQuery: String,
        isSearching: Bool,
        isSaving: Bool
    ) -> String? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching, !isSaving else { return nil }
        return query
    }

    static func shouldApplySearchCompletion(
        issuedQuery: String,
        currentQuery: String,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && issuedQuery == currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startSearch() {
        // Claim the in-flight guard synchronously before scheduling the task so
        // button taps and submit events cannot launch overlapping searches.
        guard let query = Self.preparedSearchQuery(
            searchQuery,
            isSearching: isSearching,
            isSaving: isSaving
        ) else { return }
        isSearching = true
        searchError = nil
        Task { await search(query: query) }
    }

    private func search(query: String) async {
        defer { isSearching = false }
        do {
            let results = try await searchClient.search(query)
            // The synchronous isSearching claim is the overlap guard. This stamp
            // check is defensive for future cancellation or editable-in-flight paths.
            guard Self.shouldApplySearchCompletion(
                issuedQuery: query,
                currentQuery: searchQuery,
                isCancelled: Task.isCancelled
            ) else { return }
            searchResults = results
            if results.isEmpty {
                searchError = L10n.string("No usable HTTPS images found.")
            }
        } catch {
            guard Self.shouldApplySearchCompletion(
                issuedQuery: query,
                currentQuery: searchQuery,
                isCancelled: Task.isCancelled
            ) else { return }
            searchError = UserFacingError.message(for: error)
        }
    }

    private func saveDraft() async {
        guard let draft else { return }
        await save(draft)
    }

    private func removeImage() async {
        await save(nil)
    }

    private func prepareSearchResult(_ result: GroupImageSearchResult) {
        saveError = nil
        webImageLoad?.cancel()
        let request = GroupImageCropRequest.loading()
        cropRequest = request
        webImageLoad = Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: result.imageURL)
                try Task.checkCancellation()
                cropRequest = GroupImageCropRequest.resolving(
                    cropRequest,
                    requestID: request.id,
                    with: AvatarImageCropSource(
                        data: data,
                        fileName: result.imageURL.lastPathComponent,
                        typeIdentifier: nil,
                        sourceURL: result.imageURL
                    )
                )
            } catch {
                guard !Task.isCancelled, cropRequest?.id == request.id else { return }
                cropRequest = GroupImageCropRequest.failing(cropRequest, requestID: request.id)
                saveError = UserFacingError.message(for: error)
                Haptics.error()
            }
        }
    }

    private func cancelWebImageLoad() {
        webImageLoad?.cancel()
        webImageLoad = nil
    }

    private func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String?,
        sourceURL: URL?
    ) async {
        defer {
            isPreparing = false
            progressPhase = nil
        }
        do {
            draft = try await GroupImageDraftProcessor.prepare(
                data: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier,
                sourceURL: sourceURL
            )
            Haptics.selection()
        } catch {
            saveError = UserFacingError.message(for: error)
            Haptics.error()
        }
    }

    private func save(_ draft: GroupImageUploadDraft?) async {
        isSaving = true
        progressPhase = .updating
        saveError = nil
        defer {
            isSaving = false
            progressPhase = nil
        }
        do {
            try await onSave.save(draft) { phase in
                progressPhase = phase
            }
            dismiss()
        } catch {
            saveError = UserFacingError.message(for: error)
            Haptics.error()
        }
    }
}

struct GroupImageResultCell: View {
    let result: GroupImageSearchResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.secondarySystemBackground))

                GroupImageRemoteThumbnail(url: result.thumbnailURL ?? result.imageURL)
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }

            Text(result.sourceHost ?? result.title)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let dimensionsLabel = result.dimensionsLabel {
                Text(dimensionsLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

struct GroupImageRemoteThumbnail: View {
    private static let displaySize = CGSize(width: 108, height: 92)
    private static let loadLimiter = CancellableLoadLimiter(maximumConcurrentLoads: 4)

    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var phase = Phase.loading

    var body: some View {
        content
            .task(id: url) {
                await loadImage(scale: displayScale)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .failure:
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private func loadImage(scale: CGFloat) async {
        phase = .loading
        guard let reservation = await Self.loadLimiter.acquire() else { return }
        do {
            try Task.checkCancellation()
            let image = try await RemoteAvatarImageLoader.image(
                for: url,
                maxPixelSize: Self.thumbnailMaxPixelSize(scale: scale),
                scale: scale
            )
            await Self.loadLimiter.release(reservation)
            guard !Task.isCancelled else { return }
            phase = .success(image)
        } catch {
            await Self.loadLimiter.release(reservation)
            guard !Task.isCancelled else { return }
            phase = .failure
        }
    }

    private static func thumbnailMaxPixelSize(scale: CGFloat) -> Int {
        Int(ceil(max(displaySize.width, displaySize.height) * max(scale, 1)))
    }

    private enum Phase {
        case loading
        case success(UIImage)
        case failure
    }
}

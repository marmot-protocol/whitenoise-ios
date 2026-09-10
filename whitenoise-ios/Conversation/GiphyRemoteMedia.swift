import ImageIO
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated private enum GiphyPlaybackDiagnostics {
    static let log = Logger(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "giphy-playback"
    )
}

@MainActor
@Observable
final class RemoteGIFLoadingStore {
    static let shared = RemoteGIFLoadingStore()
    static let storageKey = "media.automaticallyLoadRemoteGIFs"

    private let defaults: UserDefaults
    private(set) var automaticallyLoads: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.automaticallyLoads = defaults.bool(forKey: Self.storageKey)
    }

    func setAutomaticallyLoads(_ enabled: Bool) {
        automaticallyLoads = enabled
        defaults.set(enabled, forKey: Self.storageKey)
    }
}

@MainActor
final class GiphyPlaybackBudget {
    static let shared = GiphyPlaybackBudget(maximumConcurrentPlaybacks: 6)

    let maximumConcurrentPlaybacks: Int
    private var reservations: Set<UUID> = []
    private var waiterOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<UUID?, Never>] = [:]

    init(maximumConcurrentPlaybacks: Int) {
        self.maximumConcurrentPlaybacks = max(1, maximumConcurrentPlaybacks)
    }

    var activePlaybackCount: Int {
        reservations.count
    }

    func acquire() async -> UUID? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if reservations.count < maximumConcurrentPlaybacks {
                    let reservation = UUID()
                    reservations.insert(reservation)
                    continuation.resume(returning: reservation)
                } else {
                    waiterOrder.append(waiterID)
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(waiterID)
            }
        }
    }

    func release(_ reservation: UUID) {
        guard reservations.remove(reservation) != nil else { return }
        resumeNextWaiter()
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        waiterOrder.removeAll { $0 == waiterID }
        continuation.resume(returning: nil)
    }

    private func resumeNextWaiter() {
        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            guard let continuation = waiters.removeValue(forKey: waiterID) else { continue }
            let reservation = UUID()
            reservations.insert(reservation)
            continuation.resume(returning: reservation)
            return
        }
    }
}

nonisolated enum GiphyRemoteMediaLoader {
    struct PreparedPlayback: Sendable {
        let data: Data
        let aspectRatio: CGFloat?
    }

    static func preparePlayback(
        for media: RemoteGiphyMedia,
        apiKey: String? = GiphyBuildConfig.current().apiKey
    ) async throws -> PreparedPlayback {
        guard RemoteGiphyMedia.validatedMediaURL(media.url.absoluteString) != nil else {
            throw Failure.invalidURL
        }

        let animatedMedia: RemoteGiphyMedia
        if media.url.pathExtension.lowercased() == "gif" {
            animatedMedia = media
        } else {
            guard let apiKey else {
                GiphyPlaybackDiagnostics.log.error("legacy_lookup_failed reason=missing_api_key")
                throw Failure.invalidResponse
            }
            do {
                animatedMedia = try await GiphySearchClient(apiKey: apiKey)
                    .resolveAnimatedMedia(for: media.url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                GiphyPlaybackDiagnostics.log.error(
                    "legacy_lookup_failed error_type=\(String(reflecting: type(of: error)), privacy: .public)"
                )
                throw error
            }
        }

        return try await prepareAnimatedImage(
            url: animatedMedia.url,
            fallbackAspectRatio: animatedMedia.aspectRatio
        )
    }

    private static func prepareAnimatedImage(
        url: URL,
        fallbackAspectRatio: CGFloat
    ) async throws -> PreparedPlayback {
        let data = try await downloadedData(
            for: url,
            accept: "image/gif",
            allowedMIMETypes: ["image/gif", "application/octet-stream"]
        )
        let aspectRatio = try await Task.detached(priority: .utility) {
            try animatedImageAspectRatio(from: data)
        }.value
        return PreparedPlayback(
            data: data,
            aspectRatio: aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : fallbackAspectRatio
        )
    }

    static func animatedImageAspectRatio(from data: Data) throws -> CGFloat {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1,
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .gif) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0,
              width.isFinite,
              height.isFinite
        else {
            GiphyPlaybackDiagnostics.log.error("image_decode_failed bytes=\(data.count, privacy: .public)")
            throw Failure.invalidResponse
        }
        return CGFloat(width / height)
    }

    private static func downloadedData(
        for url: URL,
        accept: String,
        allowedMIMETypes: Set<String>
    ) async throws -> Data {
        let request = RemoteImageFetch.request(for: url, accept: accept)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await RemoteImageFetch.data(for: request)
        } catch {
            GiphyPlaybackDiagnostics.log.error(
                "media_transport_failed error_type=\(String(reflecting: type(of: error)), privacy: .public)"
            )
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            GiphyPlaybackDiagnostics.log.error("media_download_failed reason=non_http")
            throw Failure.invalidResponse
        }
        guard http.statusCode == 200,
              !data.isEmpty,
              data.count <= GiphySearchClient.maximumMediaBytes,
              let mimeType = response.mimeType?.lowercased(),
              allowedMIMETypes.contains(mimeType)
        else {
            GiphyPlaybackDiagnostics.log.error(
                "media_download_failed status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) mime=\(response.mimeType ?? "none", privacy: .public)"
            )
            throw Failure.invalidResponse
        }
        return data
    }

    enum Failure: LocalizedError {
        case invalidURL
        case invalidResponse

        var errorDescription: String? {
            L10n.string("This GIF couldn't be loaded.")
        }
    }
}

@MainActor
private final class GiphyPlaybackSession {
    let id = UUID()
    let aspectRatio: CGFloat
    let animatedImageData: Data
    private let playbackBudget: GiphyPlaybackBudget
    private let budgetReservation: UUID
    private var isStopped = false

    init(
        prepared: GiphyRemoteMediaLoader.PreparedPlayback,
        fallbackAspectRatio: CGFloat,
        playbackBudget: GiphyPlaybackBudget,
        budgetReservation: UUID
    ) {
        self.aspectRatio = prepared.aspectRatio ?? fallbackAspectRatio
        self.playbackBudget = playbackBudget
        self.budgetReservation = budgetReservation
        self.animatedImageData = prepared.data
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        playbackBudget.release(budgetReservation)
    }

    isolated deinit {
        stop()
    }
}

private struct GiphyPlaybackTaskID: Equatable {
    let contentID: String
    let isEligible: Bool
    let requestGeneration: UInt64
}

/// Keeps a timeline row's measured size independent of whether its playback
/// resource is currently resident. Visibility-driven playback teardown must
/// not revert the row to a different fallback height and feed that geometry
/// change back into the visibility calculation.
nonisolated struct StableGiphyDisplayGeometry: Equatable, Sendable {
    private(set) var aspectRatio: CGFloat

    init(fallbackAspectRatio: CGFloat) {
        aspectRatio = fallbackAspectRatio
    }

    mutating func record(decodedAspectRatio: CGFloat?) {
        guard let decodedAspectRatio,
              decodedAspectRatio.isFinite,
              decodedAspectRatio > 0
        else { return }
        aspectRatio = decodedAspectRatio
    }
}

final class GiphyAnimatedImageUIView: UIImageView {
    private var playbackID: UUID?
    private var playbackGeneration: UInt64 = 0
    private var retainedData: Data?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        isUserInteractionEnabled = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func play(data: Data, id: UUID) {
        guard playbackID != id else { return }
        stop()
        playbackID = id
        retainedData = data
        playbackGeneration &+= 1
        let generation = playbackGeneration
        let options = [kCGImageAnimationLoopCount: Double.infinity] as CFDictionary
        let status = CGAnimateImageDataWithBlock(data as CFData, options) { [weak self] _, image, stop in
            guard let self,
                  self.playbackGeneration == generation
            else {
                stop.pointee = true
                return
            }
            self.image = UIImage(cgImage: image)
        }
        if status != noErr {
            GiphyPlaybackDiagnostics.log.error("animation_start_failed status=\(status, privacy: .public)")
            stop()
        }
    }

    func stop() {
        playbackGeneration &+= 1
        playbackID = nil
        retainedData = nil
        image = nil
    }
}

private struct GiphyAnimatedImageView: UIViewRepresentable {
    let data: Data
    let playbackID: UUID

    func makeUIView(context: Context) -> GiphyAnimatedImageUIView {
        let view = GiphyAnimatedImageUIView(frame: .zero)
        view.play(data: data, id: playbackID)
        return view
    }

    func updateUIView(_ uiView: GiphyAnimatedImageUIView, context: Context) {
        uiView.play(data: data, id: playbackID)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: GiphyAnimatedImageUIView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ uiView: GiphyAnimatedImageUIView, coordinator: Void) {
        uiView.stop()
    }
}

private struct GiphyPlaybackView: View {
    let playback: GiphyPlaybackSession

    var body: some View {
        GiphyAnimatedImageView(data: playback.animatedImageData, playbackID: playback.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

struct GiphySearchPreviewView: View {
    let media: RemoteGiphyMedia

    private let playbackBudget = GiphyPlaybackBudget.shared
    @State private var playback: GiphyPlaybackSession?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let playback {
                GiphyPlaybackView(playback: playback)
            } else if didFail {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: media.url) {
            guard playback == nil, !didFail,
                  let reservation = await playbackBudget.acquire()
            else { return }
            do {
                let prepared = try await GiphyRemoteMediaLoader.preparePlayback(for: media)
                guard !Task.isCancelled else {
                    playbackBudget.release(reservation)
                    return
                }
                playback = GiphyPlaybackSession(
                    prepared: prepared,
                    fallbackAspectRatio: media.aspectRatio,
                    playbackBudget: playbackBudget,
                    budgetReservation: reservation
                )
            } catch is CancellationError {
                playbackBudget.release(reservation)
                return
            } catch {
                playbackBudget.release(reservation)
                didFail = true
            }
        }
        .onDisappear { stopPlayback() }
    }

    private func stopPlayback() {
        playback?.stop()
        playback = nil
    }
}

extension RemoteGiphyMedia {
    var creditLabel: String {
        attribution.map { L10n.formatted("via GIPHY · %@", $0) } ?? L10n.string("via GIPHY")
    }
}

struct RemoteGiphyMediaView: View {
    /// A grid cell fills a square and drops the credit row, which cannot fit;
    /// the grid carries one shared attribution line instead.
    nonisolated enum Layout: Equatable {
        case card
        case gridCell(CGSize)
        case fullscreen
    }

    let media: RemoteGiphyMedia
    let mayLoadAutomatically: Bool
    var layout: Layout = .card
    /// Set on a bubble GIF so a loaded tile opens the fullscreen gallery, the
    /// way a photo tile does. Absent while the tile is still tap-to-load.
    var onOpenFullscreen: (() -> Void)?

    @State private var loadingStore = RemoteGIFLoadingStore.shared
    private let playbackBudget = GiphyPlaybackBudget.shared
    @State private var loadRequested = false
    @State private var loadRequestGeneration: UInt64 = 0
    @State private var isLoading = false
    @State private var didFail = false
    @State private var playback: GiphyPlaybackSession?
    @State private var displayGeometry: StableGiphyDisplayGeometry
    @Environment(\.timelineRowIsVisible) private var isTimelineRowVisible

    init(
        media: RemoteGiphyMedia,
        mayLoadAutomatically: Bool,
        layout: Layout = .card,
        onOpenFullscreen: (() -> Void)? = nil
    ) {
        self.media = media
        self.mayLoadAutomatically = mayLoadAutomatically
        self.layout = layout
        self.onOpenFullscreen = onOpenFullscreen
        _displayGeometry = State(
            initialValue: StableGiphyDisplayGeometry(fallbackAspectRatio: media.aspectRatio)
        )
    }

    private var shouldLoad: Bool {
        mayLoadAutomatically || loadingStore.automaticallyLoads || loadRequested
    }

    var body: some View {
        content
            .task(id: GiphyPlaybackTaskID(
            contentID: media.url.absoluteString,
            isEligible: isTimelineRowVisible && shouldLoad,
            requestGeneration: loadRequestGeneration
        )) {
            guard isTimelineRowVisible, shouldLoad, playback == nil, !didFail else { return }
            await load()
        }
        .onDisappear { stopPlayback() }
        .onChange(of: isTimelineRowVisible) { _, isVisible in
            if !isVisible { stopPlayback() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("GIF via GIPHY"))
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .fullscreen:
            VStack(spacing: 14) {
                surface
                    .aspectRatio(displayGeometry.aspectRatio, contentMode: .fit)

                Text(media.creditLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .card:
            VStack(alignment: .leading, spacing: 0) {
                surface
                    .aspectRatio(displayGeometry.aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()

                HStack(spacing: 5) {
                    Text(media.creditLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !mayLoadAutomatically && !loadingStore.automaticallyLoads && playback != nil {
                        Image(systemName: "hand.tap")
                            .accessibilityHidden(true)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
            }
            .background(Color(.secondarySystemBackground))
        case .gridCell(let size):
            surface
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }

    @ViewBuilder
    private var surface: some View {
        let base = ZStack {
            Color.black
            if let playback {
                GiphyPlaybackView(playback: playback)
            } else {
                placeholder
            }
        }
        // While unloaded the placeholder button owns the tap, so opening
        // fullscreen only takes over once the GIF is playing.
        if let onOpenFullscreen, playback != nil {
            base
                .contentShape(.rect)
                .onTapGesture(perform: onOpenFullscreen)
        } else {
            base
        }
    }

    private var showsCompactPlaceholder: Bool {
        if case .gridCell = layout { return true }
        return false
    }

    @ViewBuilder
    private var placeholder: some View {
        if isLoading {
            ProgressView()
                .tint(.white)
        } else {
            Button {
                didFail = false
                loadRequested = true
                loadRequestGeneration &+= 1
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: didFail ? "arrow.clockwise" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.16), in: Circle())
                    if !showsCompactPlaceholder {
                        Text(didFail ? L10n.string("Retry") : L10n.string("Load GIF"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        guard let reservation = await playbackBudget.acquire() else { return }
        guard !Task.isCancelled else {
            playbackBudget.release(reservation)
            return
        }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let prepared = try await GiphyRemoteMediaLoader.preparePlayback(for: media)
            guard !Task.isCancelled else {
                playbackBudget.release(reservation)
                return
            }
            let session = GiphyPlaybackSession(
                prepared: prepared,
                fallbackAspectRatio: media.aspectRatio,
                playbackBudget: playbackBudget,
                budgetReservation: reservation
            )
            displayGeometry.record(decodedAspectRatio: session.aspectRatio)
            playback = session
        } catch is CancellationError {
            playbackBudget.release(reservation)
            return
        } catch {
            playbackBudget.release(reservation)
            didFail = true
            loadRequested = false
        }
    }

    private func stopPlayback() {
        playback?.stop()
        playback = nil
    }
}

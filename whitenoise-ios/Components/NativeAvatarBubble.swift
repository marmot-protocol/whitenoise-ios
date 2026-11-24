import SwiftUI
import MarmotKit

/// Pixels are transient UI state; MDK owns source selection, acquisition and storage.
struct NativeAvatarBubble: View {
    @Environment(AppState.self) private var appState
    let seed: String
    let title: String
    let asset: AvatarAssetFfi?
    var maxPixelSize = NativeAvatarImageCache.thumbnailPixelSize
    @State private var rendered: Rendered?

    private struct Request: Hashable {
        let account: String?
        let generation: Int
        let asset: AvatarAssetFfi?
        let erasing: Bool
        let runtimeReady: Bool
        let erasureGeneration: Int
        let maxPixelSize: Int
    }

    private struct Rendered {
        let request: Request
        let reference: String
        let revision: UInt64
        let image: UIImage
    }

    private var request: Request {
        Request(account: appState.activeAccountRef, generation: appState.runtimeGeneration,
                asset: asset, erasing: appState.isErasingAppData || AvatarCacheErasure.isInProgress,
                runtimeReady: appState.canUseRuntimeForLocalForegroundWork,
                erasureGeneration: AvatarCacheErasure.generation, maxPixelSize: maxPixelSize)
    }

    var body: some View {
        let current = request
        AvatarBubble(seed: seed, title: title,
                     pictureImage: image(for: current))
            .task(id: current) { await load(current) }
    }

    private func image(for current: Request) -> UIImage? {
        guard !current.erasing else { return nil }
        if let rendered,
           rendered.request.account == current.account,
           rendered.request.generation == current.generation,
           rendered.request.erasureGeneration == current.erasureGeneration {
            if rendered.request == current { return rendered.image }
            if current.asset?.availability == .ready || current.asset?.availability == .stale,
               current.asset?.reference == rendered.reference,
               current.asset?.contentRevision == rendered.revision { return rendered.image }
        }
        guard let account = current.account, let asset = current.asset,
              asset.availability == .ready || asset.availability == .stale,
              let reference = asset.reference else { return nil }
        let cache = NativeAvatarImageCache.shared
        return cache.image(account: account, generation: current.generation, reference: reference,
                           revision: asset.contentRevision, maxPixelSize: current.maxPixelSize)
            ?? cache.image(account: account, generation: current.generation, reference: reference,
                           revision: asset.contentRevision)
    }

    struct LoadResult {
        let reference: String
        let revision: UInt64
        let image: UIImage
    }

    static func resolveImage(
        asset: AvatarAssetFfi,
        account: String,
        generation: Int,
        maxPixelSize: Int,
        cache: NativeAvatarImageCache? = nil,
        requestAssets: (String, [String]) async throws -> [AvatarAssetFfi],
        readAssets: (String, [String], UInt64) async throws -> [AvatarBytesFfi],
        decodeImage: (Data, Int) async -> UIImage? = { data, maxPixelSize in
            await RemoteImageDecoder.downsampledImage(from: data, maxPixelSize: maxPixelSize, scale: 1)
        },
        isCurrent: () -> Bool = { true }
    ) async throws -> LoadResult? {
        let cache = cache ?? .shared
        if asset.availability == .ready,
           let reference = asset.reference,
           let image = cache.image(
               account: account,
               generation: generation,
               reference: reference,
               revision: asset.contentRevision,
               maxPixelSize: maxPixelSize
           ) {
            return LoadResult(reference: reference, revision: asset.contentRevision, image: image)
        }
        // Register visible demand only. Acquisition completes through projection updates.
        let assets = try await requestAssets(account, [asset.target])
        try Task.checkCancellation()
        guard isCurrent(),
              let available = assets.first,
              available.availability == .ready || available.availability == .stale,
              let reference = available.reference
        else { return nil }
        if let image = cache.image(
            account: account,
            generation: generation,
            reference: reference,
            revision: available.contentRevision,
            maxPixelSize: maxPixelSize
        ) {
            return LoadResult(reference: reference, revision: available.contentRevision, image: image)
        }
        let bytes = try await readAssets(account, [reference], 16 * 1024 * 1024)
        try Task.checkCancellation()
        guard let result = bytes.first, !result.deferred, !result.bytes.isEmpty else { return nil }
        let image = await decodeImage(result.bytes, maxPixelSize)
        try Task.checkCancellation()
        guard isCurrent(), let image else { return nil }
        cache.insert(
            image,
            account: account,
            generation: generation,
            reference: result.reference,
            revision: result.contentRevision,
            maxPixelSize: maxPixelSize
        )
        return LoadResult(reference: result.reference, revision: result.contentRevision, image: image)
    }

    private func load(_ current: Request) async {
        if image(for: current) == nil { rendered = nil }
        guard current.runtimeReady, !current.erasing, let asset = current.asset, let account = current.account else {
            return
        }
        if asset.availability == .ready,
           let reference = asset.reference,
           let cached = NativeAvatarImageCache.shared.image(
               account: account,
               generation: current.generation,
               reference: reference,
               revision: asset.contentRevision,
               maxPixelSize: current.maxPixelSize
           ) {
            rendered = Rendered(request: current, reference: reference, revision: asset.contentRevision, image: cached)
            return
        }
        guard let client = try? appState.currentMarmotClient() else { return }
        do {
            guard let resolved = try await Self.resolveImage(
                asset: asset,
                account: account,
                generation: current.generation,
                maxPixelSize: current.maxPixelSize,
                requestAssets: { accountRef, targets in
                    try await client.marmot.requestAvatarAssets(accountRef: accountRef, targets: targets)
                },
                readAssets: { accountRef, references, maxBytes in
                    try await client.marmot.readAvatarAssets(accountRef: accountRef, references: references, maxBytes: maxBytes)
                },
                isCurrent: { request == current && !AvatarCacheErasure.isInProgress }
            ) else { return }
            rendered = Rendered(
                request: current,
                reference: resolved.reference,
                revision: resolved.revision,
                image: resolved.image
            )
        } catch {
            // A current placeholder is preferable to a stale source or a second HTTP path.
        }
    }
}

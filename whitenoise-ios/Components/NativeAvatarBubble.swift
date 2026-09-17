import SwiftUI
import MarmotKit

/// Pixels are transient UI state; MDK owns source selection, acquisition and storage.
struct NativeAvatarBubble: View {
    @Environment(AppState.self) private var appState
    let seed: String
    let title: String
    let asset: AvatarAssetFfi?
    @State private var rendered: Rendered?

    private struct Request: Hashable {
        let account: String?
        let generation: Int
        let asset: AvatarAssetFfi?
        let erasing: Bool
        let runtimeReady: Bool
        let erasureGeneration: Int
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
                erasureGeneration: AvatarCacheErasure.generation)
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
        return NativeAvatarImageCache.shared.image(account: account, generation: current.generation,
            reference: reference, revision: asset.contentRevision)
    }

    private func load(_ current: Request) async {
        if image(for: current) == nil { rendered = nil }
        guard current.runtimeReady, !current.erasing, let asset = current.asset, let account = current.account,
              let client = try? appState.currentMarmotClient() else { return }
        do {
            // Register visible demand only. Acquisition completes through projection updates.
            let assets = try await client.marmot.requestAvatarAssets(accountRef: account, targets: [asset.target])
            try Task.checkCancellation()
            guard request == current, !AvatarCacheErasure.isInProgress,
                  let reference = assets.first?.reference else { return }
            if let available = assets.first,
               available.availability == .ready || available.availability == .stale,
               let image = NativeAvatarImageCache.shared.image(account: account, generation: current.generation,
                   reference: reference, revision: available.contentRevision) {
                rendered = Rendered(request: current, reference: reference,
                                    revision: available.contentRevision, image: image)
                return
            }
            let bytes = try await client.marmot.readAvatarAssets(accountRef: account,
                references: [reference], maxBytes: 16 * 1024 * 1024)
            try Task.checkCancellation()
            guard let result = bytes.first, !result.deferred, !result.bytes.isEmpty else { return }
            let image = await RemoteImageDecoder.downsampledImage(from: result.bytes, maxPixelSize: 384, scale: 1)
            try Task.checkCancellation()
            guard request == current, !AvatarCacheErasure.isInProgress, let image else { return }
            NativeAvatarImageCache.shared.insert(image, account: account, generation: current.generation,
                reference: result.reference, revision: result.contentRevision)
            rendered = Rendered(request: current, reference: result.reference,
                                revision: result.contentRevision, image: image)
        } catch {
            // A current placeholder is preferable to a stale source or a second HTTP path.
        }
    }
}

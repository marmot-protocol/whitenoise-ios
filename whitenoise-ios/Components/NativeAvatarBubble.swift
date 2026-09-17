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
                runtimeReady: appState.canUseRuntimeForLocalForegroundWork)
    }

    var body: some View {
        let current = request
        AvatarBubble(seed: seed, title: title,
                     pictureImage: image(for: current))
            .task(id: current) { await load(current) }
    }

    private func image(for current: Request) -> UIImage? {
        guard !current.erasing, let rendered,
              rendered.request.account == current.account,
              rendered.request.generation == current.generation else { return nil }
        if rendered.request == current { return rendered.image }
        guard current.asset?.reference == rendered.reference,
              current.asset?.contentRevision == rendered.revision else { return nil }
        return rendered.image
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
            let bytes = try await client.marmot.readAvatarAssets(accountRef: account,
                references: [reference], maxBytes: 16 * 1024 * 1024)
            try Task.checkCancellation()
            guard let result = bytes.first, !result.deferred, !result.bytes.isEmpty else { return }
            let image = await RemoteImageDecoder.downsampledImage(from: result.bytes, maxPixelSize: 384, scale: 1)
            try Task.checkCancellation()
            guard request == current, !AvatarCacheErasure.isInProgress, let image else { return }
            rendered = Rendered(request: current, reference: result.reference,
                                revision: result.contentRevision, image: image)
        } catch {
            // A current placeholder is preferable to a stale source or a second HTTP path.
        }
    }
}

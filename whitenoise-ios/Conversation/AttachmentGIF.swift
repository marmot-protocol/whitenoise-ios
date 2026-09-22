import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum AttachmentGIF {
    enum Activity { case active, inactive }

    @MainActor
    final class Playback {
        let data: Data
        let id: UUID
        private var isStopped = false

        init(data: Data, id: UUID) {
            self.data = data
            self.id = id
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            GiphyPlaybackBudget.shared.release(id)
        }

        isolated deinit { stop() }
    }

    static let maxPixelEdge: CGFloat = 4096
    private static let maxFrames = 1000
    private static let maxTotalPixels = 32 * 1024 * 1024

    // Validate before either re-encoding local imports or playing peer-controlled bytes.
    static func source(from data: Data) throws -> CGImageSource? {
        let signature = data.prefix(6)
        guard signature == Data("GIF87a".utf8) || signature == Data("GIF89a".utf8) else { return nil }
        guard data.count <= MediaDraftProcessor.maxImageAttachmentBytes else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier
        else { throw MediaDraftProcessor.Failure.unsupportedImage }
        let count = CGImageSourceGetCount(source)
        guard (1...maxFrames).contains(count), CGImageSourceGetStatus(source) == .statusComplete else {
            throw MediaDraftProcessor.Failure.unsupportedImage
        }
        // The GIF header owns the canvas size; container properties may omit it.
        let dimensions = Array(data.dropFirst(6).prefix(4))
        guard dimensions.count == 4 else { throw MediaDraftProcessor.Failure.unsupportedImage }
        let width = Int(dimensions[0]) | (Int(dimensions[1]) << 8)
        let height = Int(dimensions[2]) | (Int(dimensions[3]) << 8)
        guard (1...Int(maxPixelEdge)).contains(width), (1...Int(maxPixelEdge)).contains(height),
              width * height <= maxTotalPixels / count
        else { throw MediaDraftProcessor.Failure.unsupportedImage }
        var remainingPixels = maxTotalPixels
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...Int(maxPixelEdge)).contains(width), (1...Int(maxPixelEdge)).contains(height),
                  width * height <= remainingPixels
            else { throw MediaDraftProcessor.Failure.unsupportedImage }
            remainingPixels -= width * height
        }
        return source
    }
}

struct AttachmentGIFPlayback<Content: View>: View {
    let data: Data?
    let activity: AttachmentGIF.Activity
    @ViewBuilder let content: (AttachmentGIF.Playback?) -> Content

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback: AttachmentGIF.Playback?

    private struct TaskID: Equatable {
        let data: Data?
        let isEligible: Bool
    }

    private var taskID: TaskID {
        TaskID(data: data, isEligible: activity == .active && scenePhase == .active && !reduceMotion)
    }

    var body: some View {
        content(taskID.isEligible && playback?.data == data ? playback : nil)
            .task(id: taskID) {
                stop()
                guard taskID.isEligible, let data else { return }
                let canPlay = await Task.detached(priority: .utility) {
                    guard let source = try? AttachmentGIF.source(from: data) else { return false }
                    return CGImageSourceGetCount(source) > 1
                }.value
                guard canPlay, !Task.isCancelled, let id = await GiphyPlaybackBudget.shared.acquire() else { return }
                guard !Task.isCancelled else {
                    GiphyPlaybackBudget.shared.release(id)
                    return
                }
                playback = AttachmentGIF.Playback(data: data, id: id)
            }
            .onDisappear { stop() }
    }

    private func stop() {
        guard let playback else { return }
        playback.stop()
        self.playback = nil
    }
}

struct AttachmentGIFImage: UIViewRepresentable {
    let data: Data
    let playbackID: UUID
    let contentMode: UIView.ContentMode
    let onCompletion: () -> Void

    func makeUIView(context: Context) -> GiphyAnimatedImageUIView {
        GiphyAnimatedImageUIView(frame: .zero)
    }

    func updateUIView(_ view: GiphyAnimatedImageUIView, context: Context) {
        view.contentMode = contentMode
        view.play(data: data, id: playbackID, loopMode: .source, onCompletion: onCompletion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GiphyAnimatedImageUIView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(_ view: GiphyAnimatedImageUIView, coordinator: Void) {
        view.stop()
    }
}

import SwiftUI
import UIKit

struct ZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    let isSelected: Bool
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void
    var gifData: Data?
    var playbackID: UUID?

    func makeUIView(context: Context) -> MediaImageScrollView {
        MediaImageScrollView()
    }

    func updateUIView(_ view: MediaImageScrollView, context: Context) {
        view.onTap = onTap
        view.onZoomChanged = onZoomChanged
        view.display(image)
        view.displayGIF(data: gifData, id: playbackID)
        if !isSelected { view.setZoomScale(1, animated: false) }
    }

    static func dismantleUIView(_ view: MediaImageScrollView, coordinator: Void) {
        view.displayGIF(data: nil, id: nil)
    }
}

final class MediaImageScrollView: WNZoomScrollView {
    let imageView: GiphyAnimatedImageUIView
    private var displayedImage: UIImage?
    private var playbackID: UUID?

    init(frame: CGRect = .zero) {
        imageView = GiphyAnimatedImageUIView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        super.init(zoomedView: imageView, frame: frame)
        accessibilityLabel = L10n.string("Image")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: UIImage) {
        guard displayedImage !== image else { return }
        displayedImage = image
        imageView.image = image
        naturalContentSize = image.size
    }

    func displayGIF(data: Data?, id: UUID?) {
        guard playbackID != id else { return }
        playbackID = id
        if let data, let id {
            imageView.play(data: data, id: id, loopMode: .source)
        } else {
            imageView.stop()
            imageView.image = displayedImage
        }
    }
}

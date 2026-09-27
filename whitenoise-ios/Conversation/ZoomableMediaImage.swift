import SwiftUI
import UIKit

struct ZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    let isSelected: Bool
    let onTap: () -> Void
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> MediaImageScrollView {
        MediaImageScrollView()
    }

    func updateUIView(_ view: MediaImageScrollView, context: Context) {
        view.onTap = onTap
        view.onZoomChanged = onZoomChanged
        view.display(image)
        if !isSelected { view.setZoomScale(1, animated: false) }
    }
}

final class MediaImageScrollView: WNZoomScrollView {
    let imageView: UIImageView

    init(frame: CGRect = .zero) {
        imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        super.init(zoomedView: imageView, frame: frame)
        accessibilityLabel = L10n.string("Image")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        naturalContentSize = image.size
    }
}

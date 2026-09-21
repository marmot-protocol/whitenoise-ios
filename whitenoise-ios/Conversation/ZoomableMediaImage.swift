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

/// The image owns pans only while enlarged; at fit size the gallery owns paging.
final class MediaImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    private var viewportSize = CGSize.zero
    private var reportedZoomed = false
    var isImageZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .adjustable]
        accessibilityLabel = L10n.string("Image")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        viewportSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            setZoomScale(1, animated: false)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero,
                size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = imageView.frame.size
        }
        centerImage()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        var ancestor = superview
        while let view = ancestor {
            if let pager = view as? UIScrollView {
                pager.panGestureRecognizer.require(toFail: panGestureRecognizer)
            }
            ancestor = view.superview
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer { return isImageZoomed }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        accessibilityValue = NumberFormatter.localizedString(from: NSNumber(value: zoomScale), number: .percent)
        let zoomed = isImageZoomed
        guard reportedZoomed != zoomed else { return }
        reportedZoomed = zoomed
        // Delegate callbacks can occur during a SwiftUI update/layout pass.
        Task { @MainActor [weak self] in
            guard let self, self.reportedZoomed == zoomed else { return }
            self.onZoomChanged?(zoomed)
        }
    }

    private func centerImage() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                   y: max(contentSize.height, bounds.height) / 2)
    }

    func toggleZoom(at point: CGPoint, animated: Bool) {
        if isImageZoomed {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: animated)
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: imageView), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func singleTapped() { onTap?() }

    override func accessibilityIncrement() {
        setZoomScale(min(maximumZoomScale, zoomScale + 1), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    override func accessibilityDecrement() {
        setZoomScale(max(minimumZoomScale, zoomScale - 1), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }
}

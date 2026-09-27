import UIKit

class WNZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let zoomedView: UIView
    var onTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    var naturalContentSize = CGSize.zero {
        didSet { refit() }
    }
    private var viewportSize = CGSize.zero
    private var reportedZoomed = false
    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    init(zoomedView: UIView, frame: CGRect = .zero) {
        self.zoomedView = zoomedView
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        addSubview(zoomedView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .adjustable]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refit() {
        viewportSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              naturalContentSize.width > 0, naturalContentSize.height > 0 else { return }
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            setZoomScale(1, animated: false)
            let fit = min(bounds.width / naturalContentSize.width, bounds.height / naturalContentSize.height)
            zoomedView.frame = CGRect(origin: .zero,
                size: CGSize(width: naturalContentSize.width * fit, height: naturalContentSize.height * fit))
            contentSize = zoomedView.frame.size
        }
        centerContent()
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
        if gestureRecognizer === panGestureRecognizer { return isZoomed }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { zoomedView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        accessibilityValue = NumberFormatter.localizedString(from: NSNumber(value: zoomScale), number: .percent)
        let zoomed = isZoomed
        guard reportedZoomed != zoomed else { return }
        reportedZoomed = zoomed
        Task { @MainActor [weak self] in
            guard let self, self.reportedZoomed == zoomed else { return }
            self.onZoomChanged?(zoomed)
        }
    }

    private func centerContent() {
        zoomedView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                    y: max(contentSize.height, bounds.height) / 2)
    }

    func toggleZoom(at point: CGPoint, animated: Bool) {
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: animated)
        }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: zoomedView), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func singleTapped() { onTap?() }

    override func accessibilityIncrement() {
        setZoomScale(min(maximumZoomScale, zoomScale + 1), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }

    override func accessibilityDecrement() {
        setZoomScale(max(minimumZoomScale, zoomScale - 1), animated: window != nil && !UIAccessibility.isReduceMotionEnabled)
    }
}

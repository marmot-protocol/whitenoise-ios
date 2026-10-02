import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class MediaImageZoomTests: XCTestCase {
    private func makeViewer(size: CGSize = CGSize(width: 390, height: 844)) -> MediaImageScrollView {
        let view = MediaImageScrollView(frame: CGRect(origin: .zero, size: size))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 200, y: 150, width: 400, height: 300))
            ("Zoom detail" as NSString).draw(at: CGPoint(x: 300, y: 280),
                withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        view.display(image)
        view.layoutIfNeeded()
        return view
    }

    func testFitYieldsPansToGalleryAndDoubleTapEnablesPanning() {
        let view = makeViewer()
        XCTAssertEqual(view.imageView.frame.width, 390, accuracy: 0.1)
        XCTAssertEqual(view.imageView.center.y, 422, accuracy: 0.1)
        XCTAssertTrue(view.alwaysBounceHorizontal)
        XCTAssertTrue(view.alwaysBounceVertical)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
        view.toggleZoom(at: CGPoint(x: 195, y: 146.25), animated: false)
        XCTAssertEqual(view.zoomScale, 2.5, accuracy: 0.01)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
        view.toggleZoom(at: .zero, animated: false)
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
    }

    func testOrdinaryUpdatesPreserveZoomAndRotationRefitsImage() {
        let view = makeViewer()
        view.setZoomScale(3, animated: false)
        view.display(view.imageView.image!)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 3)
        view.frame.size = CGSize(width: 844, height: 390)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.imageView.frame.height, 390, accuracy: 0.1)
        XCTAssertEqual(view.imageView.center.x, 422, accuracy: 0.1)
    }

    func testAccessibleZoomIsBoundedAndReturnsToFit() {
        let view = makeViewer()
        for _ in 0..<10 { view.accessibilityIncrement() }
        XCTAssertEqual(view.zoomScale, 5)
        for _ in 0..<10 { view.accessibilityDecrement() }
        XCTAssertFalse(view.isZoomed)
        XCTAssertTrue(view.accessibilityTraits.contains(.adjustable))
    }

    func testRenderedFitAndZoomOnPhoneAndTablet() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            let view = makeViewer(size: size)
            view.backgroundColor = .black
            let container = UIView(frame: view.frame)
            container.addSubview(view)
            for scale: CGFloat in [1, 2.5] {
                view.setZoomScale(scale, animated: false)
                view.layoutIfNeeded()
                let visibleFrame = container.convert(view.imageView.bounds, from: view.imageView)
                XCTAssertTrue(visibleFrame.contains(CGPoint(x: size.width / 2, y: size.height / 2)))
                let rendered = UIGraphicsImageRenderer(size: size).image { context in
                    container.layer.render(in: context.cgContext)
                }
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "media-zoom-\(Int(size.width))-\(scale)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(rendered.size, size)
            }
        }
    }

    func testHostedGalleryOnlyLoadsSelectedImageAndKeepsZoomAcrossChromeUpdates() async throws {
        let image = makeViewer().imageView.image!
        let data = try XCTUnwrap(image.pngData())
        let items = ["selected", "neighbour"].map {
            MessageMediaAttachment(id: $0, reference: nil, fileName: "image.png",
                mediaType: "image/png", dim: nil, localData: nil)
        }
        let gallery = try XCTUnwrap(MessageMediaGallery(items: items, initialItem: items[0], initialImageData: Data()))
        var requestedIDs = [String]()
        let loader = ConversationMediaLoader { item in
            requestedIDs.append(item.id)
            return data
        }
        let host = UIHostingController(rootView: MessageMediaFullscreenGalleryView(
            gallery: gallery, onLoadMedia: loader, onDismiss: {}).environment(AppState.test()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        // The page decodes off the MainActor at utility priority, which a
        // loaded CI runner can starve for seconds; wait for the hosted view.
        try await waitForHostedUpdate(host) { findZoomView(host.view) != nil }
        let zoom = try XCTUnwrap(findZoomView(host.view))
        XCTAssertFalse(requestedIDs.isEmpty)
        XCTAssertEqual(Set(requestedIDs), ["selected"])
        zoom.setZoomScale(2.5, animated: false)
        try await toggleChromeAndAwaitRepresentableUpdate(zoom, host: host)
        XCTAssertEqual(zoom.zoomScale, 2.5)
        XCTAssertEqual(Set(requestedIDs), ["selected"])
        try await toggleChromeAndAwaitRepresentableUpdate(zoom, host: host)
        XCTAssertEqual(zoom.zoomScale, 2.5)
        let rendered = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "hosted-fullscreen-gallery-zoomed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `updateUIView` reassigns `onTap`, so clearing it after the tap proves
    /// the chrome change reached the representable before zoom is asserted.
    private func toggleChromeAndAwaitRepresentableUpdate(
        _ zoom: MediaImageScrollView,
        host: UIViewController
    ) async throws {
        let onTap = try XCTUnwrap(zoom.onTap)
        zoom.onTap = nil
        onTap()
        try await waitForHostedUpdate(host) { zoom.onTap != nil }
    }

    /// Runs the host's layout pass, which flushes pending SwiftUI updates, then
    /// yields the run loop until `condition` holds. The deadline only bounds a hang.
    private func waitForHostedUpdate(
        _ host: UIViewController,
        timeout: Duration = .seconds(60),
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if condition() { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("Hosted gallery did not reach the expected state within \(timeout)", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func findZoomView(_ view: UIView) -> MediaImageScrollView? {
        if let zoom = view as? MediaImageScrollView { return zoom }
        return view.subviews.lazy.compactMap { self.findZoomView($0) }.first
    }
}

import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import whitenoise_ios

@MainActor
final class MediaImageZoomTests: XCTestCase {
    func testGIFPlaybackKeepsZoom() async throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2), format: format)
        for color in [UIColor.red, .blue] {
            let image = renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let view = makeViewer()
        let poster = try XCTUnwrap(view.imageView.image)
        let id = UUID()
        view.setZoomScale(2.5, animated: false)
        view.displayGIF(data: data as Data, id: id)
        defer { view.displayGIF(data: nil, id: nil) }
        var observedColors = Set<UInt8>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while observedColors.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
            if let frame = view.imageView.image?.cgImage {
                let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                observedColors.insert(try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)[0])
            }
        }
        XCTAssertEqual(observedColors, [0, 255], "The native view must display both GIF frames")
        view.display(poster)
        view.displayGIF(data: data as Data, id: id)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 2.5)
        view.displayGIF(data: nil, id: nil)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(view.imageView.image === poster, "Cancelled callbacks must not replace the still image")
    }

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
        XCTAssertFalse(view.isImageZoomed)
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
            gallery: gallery, onLoadMedia: loader, onDismiss: {}).environment(AppState()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        host.view.layoutIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while findZoomView(host.view) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let zoom = try XCTUnwrap(findZoomView(host.view))
        XCTAssertFalse(requestedIDs.isEmpty)
        XCTAssertEqual(Set(requestedIDs), ["selected"])
        zoom.setZoomScale(2.5, animated: false)
        zoom.onTap?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(zoom.zoomScale, 2.5)
        XCTAssertEqual(Set(requestedIDs), ["selected"])
        zoom.onTap?()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(zoom.zoomScale, 2.5)
        let rendered = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "hosted-fullscreen-gallery-zoomed"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func findZoomView(_ view: UIView) -> MediaImageScrollView? {
        if let zoom = view as? MediaImageScrollView { return zoom }
        return view.subviews.lazy.compactMap { self.findZoomView($0) }.first
    }
}

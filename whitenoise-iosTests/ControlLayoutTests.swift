import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class ControlLayoutTests: XCTestCase {
    func testSharedControlsFitPhoneAndTabletAtStandardAndAccessibleTextSizes() async throws {
        for width: CGFloat in [390, 768] {
            for scheme: ColorScheme in [.light, .dark] {
                for textSize: DynamicTypeSize in [.large, .accessibility1] {
                    try await checkControls(width: width, scheme: scheme, textSize: textSize)
                }
            }
        }
    }

    private func checkControls(width: CGFloat, scheme: ColorScheme, textSize: DynamicTypeSize) async throws {
        var frames = [String: CGRect]()
        let fixture = ControlFixture { frames[$0] = $1 }
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, textSize)
        let host = UIHostingController(rootView: fixture)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1100)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        for name in ["close", "share", "add", "disabled", "empty", "filled", "input", "copy", "photo"] {
            let frame = try XCTUnwrap(frames[name], name)
            XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.01, name)
            XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.01, name)
            XCTAssertGreaterThanOrEqual(frame.minX, 0, name)
            XCTAssertLessThanOrEqual(frame.maxX, width, name)
        }
        let close = try XCTUnwrap(frames["close"])
        for name in ["share", "add", "disabled"] {
            let frame = try XCTUnwrap(frames[name])
            XCTAssertEqual(frame.width, frame.height, accuracy: 1, name)
            XCTAssertEqual(frame.height, close.height, accuracy: 1, name)
        }
        XCTAssertEqual(try XCTUnwrap(frames["empty"]).height,
                       try XCTUnwrap(frames["filled"]).height, accuracy: 1)
        let rendered = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "controls-\(Int(width))-\(scheme)-\(textSize)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct ControlFixture: View {
    let record: (String, CGRect) -> Void
    @State private var empty = ""
    @State private var filled = "Message search"
    @State private var name = "Profile name"
    @State private var showPhotos = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Shared controls").font(.title2)
                HStack(spacing: 12) {
                    measured("close") { WNIconButton(title: "Close", systemImage: "xmark") {} }
                    measured("share") { WNIconButton(title: "Share", systemImage: "square.and.arrow.up") {} }
                    measured("add") { WNIconButton(title: "Add", systemImage: "plus", emphasis: .primary) {} }
                    measured("disabled") { WNIconButton(title: "Close", systemImage: "xmark") {}.disabled(true) }
                }
                measured("empty") { WNSearchField(query: $empty, prompt: "Search people", onPaste: {}, onScan: {}) }
                measured("filled") { WNSearchField(query: $filled, prompt: "Search messages") }
                WNSearchBar(query: $filled, prompt: "Search Chats", focusesOnAppear: false) {}
                measured("input") { WNInput(placeholder: "Name", text: $name, showsClear: true) }
                measured("copy") { CopyableValueChip(display: "npub1exam…f4k2", copyValue: "example", valueName: "npub") }
                measured("photo") { WNPhotoMenuButton(hasPhoto: false, isPresented: $showPhotos) }
                WNButton(title: "Continue") {}
                WNButton(title: "Cancel", emphasis: .secondary) {}
                WNButton(title: "Delete", emphasis: .destructive, size: .standard) {}
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .coordinateSpace(name: "fixture")
    }

    private func measured<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        content().onGeometryChange(for: CGRect.self) { $0.frame(in: .named("fixture")) } action: { record(name, $0) }
    }
}

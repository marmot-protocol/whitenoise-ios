import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class ControlLayoutTests: XCTestCase {
    func testAvatarFormKeepsItsGeometryWhenAppearanceChangesWhileVisible() async throws {
        var frames = [String: CGRect]()
        var appearances = [String: ColorScheme]()
        var expectedScheme = ColorScheme.light
        var layoutReady: XCTestExpectation?
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: AvatarFormFixture { name, frame, scheme in
            frames[name] = frame
            appearances[name] = scheme
            if ["avatar", "add", "change"].allSatisfy({ appearances[$0] == expectedScheme && frames[$0]?.isEmpty == false }) {
                layoutReady?.fulfill()
                layoutReady = nil
            }
        }.tint(.accentColor))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        var baseline = [String: CGRect]()
        for style in [UIUserInterfaceStyle.light, .dark, .light] {
            expectedScheme = style == .dark ? .dark : .light
            let ready = expectation(description: "Avatar form laid out in \(expectedScheme)")
            layoutReady = ready
            window.overrideUserInterfaceStyle = style
            host.view.layoutIfNeeded()
            if ["avatar", "add", "change"].allSatisfy({ appearances[$0] == expectedScheme && frames[$0]?.isEmpty == false }) {
                layoutReady?.fulfill()
                layoutReady = nil
            }
            await fulfillment(of: [ready], timeout: 30)
            host.view.layoutIfNeeded()
            for name in ["avatar", "add", "change"] {
                let frame = try XCTUnwrap(frames[name])
                if let expected = baseline[name] {
                    XCTAssertEqual(frame.width, expected.width, accuracy: 0.5, name)
                    XCTAssertEqual(frame.height, expected.height, accuracy: 0.5, name)
                    XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.5, name)
                    XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.5, name)
                } else { baseline[name] = frame }
            }
            let rendered = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "avatar-form-\(style.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSharedControlsFitPhoneAndTabletAtStandardAndAccessibleTextSizes() async throws {
        for width: CGFloat in [390, 768] {
            for textSize: DynamicTypeSize in [.large, .accessibility1] {
                let light = try await checkControls(width: width, scheme: .light, textSize: textSize)
                let dark = try await checkControls(width: width, scheme: .dark, textSize: textSize)
                for (name, lightFrame) in light {
                    let darkFrame = try XCTUnwrap(dark[name], name)
                    XCTAssertEqual(lightFrame.width, darkFrame.width, accuracy: 0.5, "\(name) changes width with appearance")
                    XCTAssertEqual(lightFrame.height, darkFrame.height, accuracy: 0.5, "\(name) changes height with appearance")
                    XCTAssertEqual(lightFrame.minX, darkFrame.minX, accuracy: 0.5, "\(name) moves horizontally with appearance")
                    XCTAssertEqual(lightFrame.minY, darkFrame.minY, accuracy: 0.5, "\(name) moves vertically with appearance")
                }
            }
        }
    }

    private func checkControls(width: CGFloat, scheme: ColorScheme, textSize: DynamicTypeSize) async throws -> [String: CGRect] {
        var frames = [String: CGRect]()
        let fixture = ControlFixture { frames[$0] = $1 }
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, textSize)
        let host = UIHostingController(rootView: fixture)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1100)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.tintColor = UIColor(named: "AccentColor")
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        for name in ["close", "share", "add", "disabled", "empty", "filled", "input", "copy", "photo", "changePhoto", "disabledPhoto", "primary", "secondary", "destructive", "loading"] {
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
        return frames
    }
}

private struct AvatarFormFrame: Equatable {
    let rect: CGRect
    let scheme: ColorScheme
}

private struct AvatarFormFixture: View {
    @Environment(\.colorScheme) private var scheme
    let record: (String, CGRect, ColorScheme) -> Void
    @State private var isPresented = false

    var body: some View {
        Form {
            VStack(spacing: 0) {
                WNAvatarPreview(name: "Example")
                    .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
                WNPhotoMenuButton(hasPhoto: false, isPresented: $isPresented).padding(.top)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .onGeometryChange(for: AvatarFormFrame.self) {
                    AvatarFormFrame(rect: $0.frame(in: .global), scheme: scheme)
                } action: { record("avatar", $0.rect, $0.scheme) }
            WNPhotoMenuButton(hasPhoto: false, isPresented: $isPresented)
                .onGeometryChange(for: AvatarFormFrame.self) {
                    AvatarFormFrame(rect: $0.frame(in: .global), scheme: scheme)
                } action: { record("add", $0.rect, $0.scheme) }
            WNPhotoMenuButton(hasPhoto: true, isPresented: $isPresented)
                .onGeometryChange(for: AvatarFormFrame.self) {
                    AvatarFormFrame(rect: $0.frame(in: .global), scheme: scheme)
                } action: { record("change", $0.rect, $0.scheme) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(.background)
    }
}

private struct ControlFixture: View {
    let record: (String, CGRect) -> Void
    @State private var empty = ""
    @State private var filled = "Message search"
    @State private var name = "Profile name"
    @State private var isPresented = false

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
                measured("photo") { WNPhotoMenuButton(hasPhoto: false, isPresented: $isPresented) }
                measured("changePhoto") { WNPhotoMenuButton(hasPhoto: true, isPresented: $isPresented) }
                measured("disabledPhoto") { WNPhotoMenuButton(hasPhoto: false, isPresented: $isPresented).disabled(true) }
                measured("primary") { WNButton(title: "Continue") {} }
                measured("secondary") { WNButton(title: "Cancel", emphasis: .secondary) {} }
                measured("destructive") { WNButton(title: "Delete", emphasis: .destructive, size: .standard) {} }
                measured("loading") { WNButton(title: "Continue", isLoading: true) {} }
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

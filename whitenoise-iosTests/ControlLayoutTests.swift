import SwiftUI
import XCTest
@testable import whitenoise_ios

/// Measures the shared controls through their own geometry callbacks: each
/// configuration renders once and is read when every control has reported,
/// with no fixed wait and no screenshots.
@MainActor
final class ControlLayoutTests: XCTestCase {
    func testAvatarFormKeepsItsGeometryWhenAppearanceChangesWhileVisible() async throws {
        let names = ["avatar", "add", "change"]
        var frames = [String: CGRect]()
        var appearances = [String: ColorScheme]()
        var expectedScheme = ColorScheme.light
        var layoutReady: XCTestExpectation?
        func fulfilIfLaidOut() {
            if names.allSatisfy({ appearances[$0] == expectedScheme && frames[$0]?.isEmpty == false }) {
                layoutReady?.fulfill()
                layoutReady = nil
            }
        }
        let host = UIHostingController(rootView: AvatarFormFixture { name, frame, scheme in
            frames[name] = frame
            appearances[name] = scheme
            fulfilIfLaidOut()
        }.tint(.accentColor))
        // One visible hierarchy for all three passes: the appearance changes in place.
        try await withHostedWindow(host, frame: CGRect(x: 0, y: 0, width: 390, height: 844), style: .light) { window in
            var baseline = [String: CGRect]()
            for style in [UIUserInterfaceStyle.light, .dark, .light] {
                expectedScheme = style == .dark ? .dark : .light
                let ready = expectation(description: "Avatar form laid out in \(expectedScheme)")
                layoutReady = ready
                window.overrideUserInterfaceStyle = style
                host.view.layoutIfNeeded()
                fulfilIfLaidOut()
                await fulfillment(of: [ready], timeout: 30)
                host.view.layoutIfNeeded()
                for name in names {
                    let frame = try XCTUnwrap(frames[name])
                    if let expected = baseline[name] {
                        XCTAssertEqual(frame.width, expected.width, accuracy: 0.5, name)
                        XCTAssertEqual(frame.height, expected.height, accuracy: 0.5, name)
                        XCTAssertEqual(frame.minX, expected.minX, accuracy: 0.5, name)
                        XCTAssertEqual(frame.minY, expected.minY, accuracy: 0.5, name)
                    } else { baseline[name] = frame }
                }
            }
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

    private static let measuredControls = [
        "close", "share", "add", "disabled", "empty", "filled", "input", "copy", "photo", "changePhoto",
        "disabledPhoto", "primary", "secondary", "destructive", "loading",
    ]

    private func checkControls(width: CGFloat, scheme: ColorScheme, textSize: DynamicTypeSize) async throws -> [String: CGRect] {
        var frames = [String: CGRect]()
        let ready = expectation(description: "Controls laid out at \(Int(width)) \(scheme) \(textSize)")
        var fulfilled = false
        let fixture = ControlFixture { name, frame in
            frames[name] = frame
            if !fulfilled, Self.measuredControls.allSatisfy({ frames[$0] != nil }) {
                fulfilled = true
                ready.fulfill()
            }
        }
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, textSize)
        let host = UIHostingController(rootView: fixture)
        // SwiftUI reports geometry only for a hierarchy in a window.
        try await withHostedWindow(host, frame: CGRect(x: 0, y: 0, width: width, height: 1100),
                                   style: scheme == .dark ? .dark : .light) { _ in
            await fulfillment(of: [ready], timeout: 30)
            // Settle any follow-up pass the first geometry reports triggered.
            host.view.layoutIfNeeded()
        }
        for name in Self.measuredControls {
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
    @State private var selection: WNPhotoMenuAction?

    var body: some View {
        Form {
            WNAvatarPhotoMenu(hasPhoto: false, selection: $selection) {
                WNAvatarPreview(name: "Example")
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .onGeometryChange(for: AvatarFormFrame.self) {
                    AvatarFormFrame(rect: $0.frame(in: .global), scheme: scheme)
                } action: { record("avatar", $0.rect, $0.scheme) }
            WNPhotoMenuButton(hasPhoto: false, selection: $selection)
                .onGeometryChange(for: AvatarFormFrame.self) {
                    AvatarFormFrame(rect: $0.frame(in: .global), scheme: scheme)
                } action: { record("add", $0.rect, $0.scheme) }
            WNPhotoMenuButton(hasPhoto: true, selection: $selection)
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
    @State private var photoMenuAction: WNPhotoMenuAction?

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
                measured("photo") { WNPhotoMenuButton(hasPhoto: false, selection: $photoMenuAction) }
                measured("changePhoto") { WNPhotoMenuButton(hasPhoto: true, selection: $photoMenuAction) }
                measured("disabledPhoto") { WNPhotoMenuButton(hasPhoto: false, selection: $photoMenuAction).disabled(true) }
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

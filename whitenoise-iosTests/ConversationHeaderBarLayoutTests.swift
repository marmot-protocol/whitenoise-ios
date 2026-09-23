import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class ConversationHeaderBarLayoutTests: XCTestCase {
    func testTheIdentityClusterStaysOnTheBarMidlineWhicheverControlIsShowing() async throws {
        for width: CGFloat in [390, 768] {
            for textSize: DynamicTypeSize in [.large, .accessibility1] {
                for selecting in [false, true] {
                    let frames = try await render(width: width, textSize: textSize, selecting: selecting)
                    let bar = try XCTUnwrap(frames["bar"])
                    let title = try XCTUnwrap(frames["title"])
                    let label = "\(Int(width))-\(textSize)-selecting:\(selecting)"
                    XCTAssertEqual(title.midX, bar.midX, accuracy: 1, label)
                }
            }
        }
    }

    func testALongTitleTruncatesBeforeItReachesEitherEdgeControl() async throws {
        for width: CGFloat in [390, 768] {
            for textSize: DynamicTypeSize in [.large, .accessibility1] {
                for selecting in [false, true] {
                    let frames = try await render(width: width, textSize: textSize, selecting: selecting)
                    let bar = try XCTUnwrap(frames["bar"])
                    let title = try XCTUnwrap(frames["title"])
                    let control = try XCTUnwrap(frames["control"])
                    let label = "\(Int(width))-\(textSize)-selecting:\(selecting)"
                    let reserved = control.width + ConversationHeaderMetrics.horizontalPadding
                    XCTAssertGreaterThan(title.width, 0, label)
                    XCTAssertGreaterThanOrEqual(title.minX, bar.minX + reserved, label)
                    XCTAssertLessThanOrEqual(title.maxX, bar.maxX - reserved, label)
                }
            }
        }
    }

    private func render(
        width: CGFloat,
        textSize: DynamicTypeSize,
        selecting: Bool
    ) async throws -> [String: CGRect] {
        var frames = [String: CGRect]()
        let fixture = HeaderFixture(selecting: selecting) { frames[$0] = $1 }
            .environment(\.dynamicTypeSize, textSize)
        let host = UIHostingController(rootView: fixture)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        return frames
    }
}

private struct HeaderFixture: View {
    let selecting: Bool
    let record: (String, CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeaderBar(
                isSelectingMessages: selecting,
                onBack: {},
                onClose: {}
            ) {
                HStack(spacing: 10) {
                    Circle()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "A conversation title long enough to want the whole bar")
                            .font(.headline)
                            .lineLimit(1)
                        Text(verbatim: "12 members")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .measured("title", record: record)
            }
            .measured("bar", record: record)

            // The bar's controls live inside a generic view the test cannot
            // reach into, so the same component off to the side gives the real
            // control width at this text size.
            WNIconButton(title: "Back", systemImage: "chevron.backward") {}
                .measured("control", record: record)

            Spacer(minLength: 0)
        }
        .coordinateSpace(name: "fixture")
    }
}

private extension View {
    func measured(_ name: String, record: @escaping (String, CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("fixture")) } action: { record(name, $0) }
    }
}

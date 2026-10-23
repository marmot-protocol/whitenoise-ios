import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class ConversationHeaderBarLayoutTests: XCTestCase {
    /// One render per configuration checks both header rules: the identity
    /// cluster sits on the bar's midline whichever control is showing, and a
    /// long title truncates before it reaches either edge control.
    func testTheTitleStaysCenteredAndClearOfTheEdgeControls() async throws {
        for width: CGFloat in [390, 768] {
            for textSize: DynamicTypeSize in [.large, .accessibility1] {
                for selecting in [false, true] {
                    let frames = try await render(width: width, textSize: textSize, selecting: selecting)
                    let bar = try XCTUnwrap(frames["bar"])
                    let title = try XCTUnwrap(frames["title"])
                    let control = try XCTUnwrap(frames["control"])
                    let label = "\(Int(width))-\(textSize)-selecting:\(selecting)"

                    XCTAssertEqual(title.midX, bar.midX, accuracy: 1, label)

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
        let report = FrameReport(expecting: ["bar", "title", "control"])
        let fixture = HeaderFixture(selecting: selecting) { report.record($0, $1) }
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
        let reported = await report.frames(timeout: .seconds(5))
        _ = try XCTUnwrap(
            reported,
            "header geometry did not report at \(Int(width))-\(textSize)-selecting:\(selecting)"
        )
        // The first complete set can precede the final pass; settle once more
        // and read whatever the callbacks reported since.
        host.view.layoutIfNeeded()
        await Task.yield()
        return report.latest
    }
}

/// Resolves once every expected view has reported a non-empty frame, or with
/// nil when the timeout passes first; no fixed sleeps on the happy path.
@MainActor
private final class FrameReport {
    private let expected: Set<String>
    private var frames = [String: CGRect]()
    private var waiter: CheckedContinuation<[String: CGRect]?, Never>?

    init(expecting expected: Set<String>) {
        self.expected = expected
    }

    var latest: [String: CGRect] { frames }

    private var isComplete: Bool {
        expected.allSatisfy { frames[$0]?.isEmpty == false }
    }

    func record(_ name: String, _ frame: CGRect) {
        frames[name] = frame
        if isComplete {
            resume(with: frames)
        }
    }

    func frames(timeout: Duration) async -> [String: CGRect]? {
        if isComplete { return frames }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(with: nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func resume(with frames: [String: CGRect]?) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: frames)
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

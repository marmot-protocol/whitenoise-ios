import SwiftUI
import XCTest
@testable import whitenoise_ios

@MainActor
final class ProfileFormLayoutTests: XCTestCase {
    func testAboutKeepsMinimumHeightWhenEditingWithoutTruncatingLongBios() async throws {
        // One window for every configuration; each swaps in a fresh root and
        // waits for the section's own height callback (SwiftUI reports
        // geometry only for a hierarchy in a window).
        try await withHostedWindow(UIViewController()) { window in
            for text in ["", "A short bio", (1...8).map { "Bio line \($0)" }.joined(separator: "\n")] {
                var heights = [CGFloat]()
                for isEditing in [false, true] {
                    let ready = expectation(description: "About laid out in \(isEditing ? "edit" : "view") mode")
                    var measured = false
                    let host = UIHostingController(rootView: ProfileAboutFixture(text: text, isEditing: isEditing) { height in
                        guard height > 0, !measured else { return }
                        measured = true
                        heights.append(height)
                        ready.fulfill()
                    })
                    window.rootViewController = host
                    host.view.layoutIfNeeded()
                    await fulfillment(of: [ready], timeout: 10)
                    // Visual evidence in the result bundle, taken after the geometry wait.
                    let rendered = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: rendered)
                    attachment.name = "about-\(text.isEmpty ? "empty" : text.contains("\n") ? "long" : "short")-\(isEditing ? "edit" : "view")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(heights.count, 2)
                guard heights.count == 2 else { continue }
                if text.contains("\n") {
                    // The editor scrolls after six lines; viewing must still expose the entire bio.
                    XCTAssertGreaterThan(heights[0], heights[1])
                } else {
                    XCTAssertEqual(heights[0], heights[1], accuracy: 1)
                }
            }
        }
    }
}

private struct ProfileAboutFixture: View {
    let text: String
    let isEditing: Bool
    let onHeight: (CGFloat) -> Void
    @FocusState private var focus: WNProfileField?

    var body: some View {
        Form {
            WNProfileAboutSection(text: .constant(text), focus: $focus, isEditing: isEditing, onHeightChange: onHeight)
        }
        .environment(\.dynamicTypeSize, .large)
    }
}

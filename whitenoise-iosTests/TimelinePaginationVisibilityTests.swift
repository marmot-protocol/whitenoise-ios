import Combine
import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
private final class PaginationScrollModel: ObservableObject {
    @Published var target = "bottom"
    @Published var isEnabled = true
    var olderRequests = 0
    var newerRequests = 0
    var visibleTargets = Set<String>()
}

private struct PaginationScrollHarness: View {
    @ObservedObject var model: PaginationScrollModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    Color.clear.frame(height: 28)
                        .modifier(TimelinePaginationVisibility(isEnabled: model.isEnabled) {
                            model.olderRequests += 1
                        })
                        .id("top")
                    ForEach(0..<100) { index in
                        Text("Message \(index)").frame(height: 80).id("row-\(index)")
                    }
                    Color.clear.frame(height: 1)
                        .modifier(TimelinePaginationVisibility(isEnabled: model.isEnabled) {
                            model.newerRequests += 1
                        })
                        .id("bottom")
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .task(id: model.target) {
                await Task.yield()
                proxy.scrollTo(model.target, anchor: model.target == "top" ? .top : .bottom)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.001) {
                model.visibleTargets = Set($0)
            }
        }
    }
}

@MainActor
@Suite(.serialized)
struct TimelinePaginationVisibilityTests {
    private func makeWindow(model: PaginationScrollModel) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: PaginationScrollHarness(model: model))
        window.makeKeyAndVisible()
        return window
    }

    private func settle(_ window: UIWindow, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            window.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        #expect(condition(), "Scroll visibility did not reach the requested state")
    }

    @Test func eagerTimelineLoadsOnlyTheVisibleEdgeAndRearmsAfterLeavingIt() async throws {
        let model = PaginationScrollModel()
        let window = try makeWindow(model: model)
        defer { window.isHidden = true }

        try await settle(window) { model.visibleTargets.contains("bottom") && model.newerRequests == 1 }
        #expect(model.olderRequests == 0, "Mounting offscreen history must not paginate backwards")

        model.target = "row-50"
        try await settle(window) {
            model.visibleTargets.contains("row-50") && !model.visibleTargets.contains("bottom")
        }
        #expect(model.olderRequests == 0)
        #expect(model.newerRequests == 1)

        model.target = "top"
        try await settle(window) { model.visibleTargets.contains("top") && model.olderRequests == 1 }
        #expect(model.newerRequests == 1)

        model.target = "bottom"
        try await settle(window) { model.visibleTargets.contains("bottom") && model.newerRequests == 2 }
        #expect(model.olderRequests == 1)
    }

    @Test func initialPositioningDefersPaginationUntilTheVisibleTargetSettles() async throws {
        let model = PaginationScrollModel()
        model.isEnabled = false
        let window = try makeWindow(model: model)
        defer { window.isHidden = true }
        try await settle(window) { model.visibleTargets.contains("bottom") }
        #expect(model.olderRequests == 0)
        #expect(model.newerRequests == 0)

        model.isEnabled = true
        try await settle(window) { model.newerRequests == 1 }
        #expect(model.olderRequests == 0)
        model.isEnabled = false
        await Task.yield()
        model.isEnabled = true
        await Task.yield()
        #expect(model.newerRequests == 1, "A loading-state change must not duplicate the visible page request")
    }
}

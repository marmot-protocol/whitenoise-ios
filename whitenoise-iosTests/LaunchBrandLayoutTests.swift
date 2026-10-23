import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized, .tags(.runtime, .uiHosting), .marmotRuntimeConcurrencyLimit)
struct LaunchBrandLayoutTests {
    private static let markIdentifier = "launch.mark"

    @Test(arguments: [
        CGSize(width: 320, height: 568),
        CGSize(width: 912, height: 420),
        CGSize(width: 834, height: 1194),
    ])
    func launchAndRuntimeLoadingKeepTheSameMarkFrame(size: CGSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        defer { window.isHidden = true }

        let launch = try #require(UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController())
        window.rootViewController = launch
        window.makeKeyAndVisible()
        launch.view.layoutIfNeeded()
        let launchMark = try #require(Self.mark(in: launch.view))
        // A blank splash would still lay out an empty view under the identifier.
        let launchImage = try #require(launchMark as? UIImageView)
        #expect(launchImage.image != nil)
        let expected = launchMark.convert(launchMark.bounds, to: window)
        #expect(expected.width > 0)
        #expect(expected.height <= size.height * 0.3 + 1)
        #expect(abs(expected.midX - size.width / 2) < 1)
        #expect(abs(expected.midY - size.height / 2) < 1)

        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let loading = UIHostingController(rootView:
                LaunchBrandView().ignoresSafeArea()
                    .environment(\.dynamicTypeSize, textSize)
            )
            window.rootViewController = loading
            loading.view.layoutIfNeeded()
            await Task.yield()
            loading.view.layoutIfNeeded()
            let loadingMark = try #require(Self.mark(in: loading.view))
            #expect((loadingMark as? UIImageView)?.image != nil)
            let actual = loadingMark.convert(loadingMark.bounds, to: window)
            #expect(abs(actual.minX - expected.minX) < 1)
            #expect(abs(actual.minY - expected.minY) < 1)
            #expect(abs(actual.width - expected.width) < 1)
            #expect(abs(actual.height - expected.height) < 1)
        }
    }

    // 912x420 is the compact-height case that lays Welcome out side by side.
    @Test(arguments: [
        CGSize(width: 320, height: 568),
        CGSize(width: 912, height: 420),
        CGSize(width: 1194, height: 834),
    ])
    func welcomeMarkRemainsVisibleAndBounded(size: CGSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let appState = AppState.test(client: try MarmotClient.testClient())
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            // Navigation can publish a zero-size frame before its first usable layout.
            let report = MarkFrameReport()
            let welcome = UIHostingController(rootView:
                NavigationStack { WelcomeView() }
                    .environment(appState)
                    .environment(\.dynamicTypeSize, textSize)
                    .environment(\.verticalSizeClass, size.height < 500 ? .compact : .regular)
                    .overlayPreferenceValue(WelcomeBrandBoundsKey.self) { anchor in
                        GeometryReader { geometry in
                            Color.clear
                                .onChange(of: anchor.map { geometry[$0] }, initial: true) { _, frame in
                                    report.record(frame)
                                }
                        }
                        .allowsHitTesting(false)
                    }
            )
            window.rootViewController = welcome
            window.makeKeyAndVisible()
            welcome.view.layoutIfNeeded()

            // SwiftUI Image need not create a UIImageView; measure its rendered layout instead.
            let actual = try #require(
                await report.usableFrame(timeout: .seconds(5)),
                "Welcome logo did not report layout for \(size), \(textSize)"
            )
            #expect(actual.width > 0)
            #expect(actual.height > 0)
            #expect(actual.width <= window.bounds.width * 0.5 + 1)
            #expect(actual.height <= window.bounds.height * 0.3 + 1)
            #expect(window.bounds.insetBy(dx: -1, dy: -1).contains(actual))
        }
    }

    private static func mark(in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == markIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap { mark(in: $0) }.first
    }
}

/// Resolves once the Welcome brand reports a non-empty frame, or with nil when
/// the timeout passes first; no fixed sleeps on the happy path.
@MainActor
private final class MarkFrameReport {
    private var frame: CGRect?
    private let reported = TestLatch()

    func record(_ frame: CGRect?) {
        guard let frame, !frame.isEmpty else { return }
        self.frame = frame
        reported.signal()
    }

    func usableFrame(timeout: Duration) async -> CGRect? {
        try? await reported.wait(timeout: timeout)
        return frame
    }
}

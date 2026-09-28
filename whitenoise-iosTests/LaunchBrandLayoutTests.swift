import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct LaunchBrandLayoutTests {
    @Test(arguments: [
        CGSize(width: 320, height: 568),
        CGSize(width: 420, height: 912),
        CGSize(width: 912, height: 420),
        CGSize(width: 834, height: 1194),
        CGSize(width: 1194, height: 834),
        CGSize(width: 320, height: 1024),
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
        let launchMark = try #require(mark(in: launch.view))
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
            let loadingMark = try #require(mark(in: loading.view))
            let actual = loadingMark.convert(loadingMark.bounds, to: window)
            #expect(abs(actual.minX - expected.minX) < 1)
            #expect(abs(actual.minY - expected.minY) < 1)
            #expect(abs(actual.width - expected.width) < 1)
            #expect(abs(actual.height - expected.height) < 1)
        }
    }

    @Test(arguments: [
        CGSize(width: 320, height: 568),
        CGSize(width: 912, height: 420),
        CGSize(width: 834, height: 1194),
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

        let appState = AppState(client: try MarmotClient.testClient())
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            var markFrame: CGRect?
            let welcome = UIHostingController(rootView:
                NavigationStack { WelcomeView() }
                    .environment(appState)
                    .environment(\.dynamicTypeSize, textSize)
                    .environment(\.verticalSizeClass, size.height < 500 ? .compact : .regular)
                    .overlayPreferenceValue(WelcomeBrandBoundsKey.self) { anchor in
                        GeometryReader { geometry in
                            Color.clear
                                .onChange(of: anchor.map { geometry[$0] }, initial: true) { _, frame in
                                    markFrame = frame
                                }
                        }
                        .allowsHitTesting(false)
                    }
            )
            window.rootViewController = welcome
            window.makeKeyAndVisible()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            // Navigation can publish a zero-size frame before its first usable layout.
            while markFrame?.isEmpty != false, ContinuousClock.now < deadline {
                welcome.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }

            // SwiftUI Image need not create a UIImageView; measure its rendered layout instead.
            let actual = try #require(markFrame, "Welcome logo did not report layout for \(size), \(textSize)")
            #expect(actual.width > 0)
            #expect(actual.height > 0)
            #expect(actual.width <= window.bounds.width * 0.5 + 1)
            #expect(actual.height <= window.bounds.height * 0.3 + 1)
            #expect(window.bounds.insetBy(dx: -1, dy: -1).contains(actual))
        }
    }

    private func mark(in view: UIView) -> UIImageView? {
        if let image = view as? UIImageView, image.image?.size == CGSize(width: 598, height: 460) {
            return image
        }
        return view.subviews.lazy.compactMap { mark(in: $0) }.first
    }
}

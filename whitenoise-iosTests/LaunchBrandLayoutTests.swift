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
    func launchAndWelcomeKeepTheSameMarkFrame(size: CGSize) async throws {
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

        let appState = AppState(client: try MarmotClient.testClient())
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let welcome = UIHostingController(rootView:
                NavigationStack { WelcomeView() }
                    .environment(appState)
                    .environment(\.dynamicTypeSize, textSize)
            )
            window.rootViewController = welcome
            welcome.view.layoutIfNeeded()
            await Task.yield()
            welcome.view.layoutIfNeeded()
            let welcomeMark = try #require(mark(in: welcome.view))
            let actual = welcomeMark.convert(welcomeMark.bounds, to: window)
            #expect(abs(actual.minX - expected.minX) < 1)
            #expect(abs(actual.minY - expected.minY) < 1)
            #expect(abs(actual.width - expected.width) < 1)
            #expect(abs(actual.height - expected.height) < 1)
        }
    }

    private func mark(in view: UIView) -> UIImageView? {
        if let image = view as? UIImageView, image.image?.size == CGSize(width: 598, height: 460) {
            return image
        }
        return view.subviews.lazy.compactMap { mark(in: $0) }.first
    }
}

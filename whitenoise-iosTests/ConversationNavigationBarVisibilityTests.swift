import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct ConversationNavigationBarVisibilityTests {
    @Test func conversationHidesTheBarAndRestoresItForDetailsAndBack() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let conversation = UIHostingController(rootView:
            Text("Conversation")
                .background { ConversationNavigationBarVisibility() }
        )
        navigation.pushViewController(conversation, animated: false)
        window.layoutIfNeeded()
        #expect(navigation.navigationBar.isHidden)

        navigation.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        #expect(!navigation.navigationBar.isHidden)

        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        #expect(navigation.navigationBar.isHidden)

        navigation.popViewController(animated: false)
        window.layoutIfNeeded()
        #expect(!navigation.navigationBar.isHidden)
        #expect(navigation.topViewController === root)
    }
}

import SwiftUI
import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
@Suite
struct ConversationNavigationBarVisibilityTests {
    @Test func conversationHidesTheBarAndRestoresItForDetailsAndBack() async throws {
        let root = UIViewController()
        let navigation = UINavigationController(rootViewController: root)
        try await withHostedWindow(navigation) { window in

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
}

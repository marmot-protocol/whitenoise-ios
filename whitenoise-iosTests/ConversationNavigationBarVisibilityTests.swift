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

    @Test func conversationKeepsTheBarHiddenWhenRebuiltInPlace() async throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let identity = RebuildIdentity()
        try await withHostedWindow(navigation) { window in
            navigation.pushViewController(
                UIHostingController(rootView: RebuildingConversation(identity: identity)),
                animated: false
            )
            try await settleLayout(window) { navigation.navigationBar.isHidden }
            #expect(navigation.navigationBar.isHidden)

            identity.generation += 1
            try await settleLayout(window) { navigation.navigationBar.isHidden }
            #expect(navigation.navigationBar.isHidden)

            navigation.popViewController(animated: false)
            try await settleLayout(window) { navigation.navigationBar.isHidden }
            #expect(!navigation.navigationBar.isHidden)
        }
    }
}

@MainActor @Observable
private final class RebuildIdentity {
    var generation = 0
}

private struct RebuildingConversation: View {
    let identity: RebuildIdentity

    var body: some View {
        Text("Conversation")
            .background {
                ConversationNavigationBarVisibility()
                    .id(identity.generation)
            }
    }
}

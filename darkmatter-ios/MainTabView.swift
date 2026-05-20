import SwiftUI

/// Main app shell once at least one identity exists. Two top-level
/// destinations — Chats and Settings — matching Messages-app shape.
struct MainTabView: View {
    @State private var selectedTab: Tab = .chats

    enum Tab: Hashable {
        case chats
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ChatsListView()
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(Tab.chats)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
    }
}

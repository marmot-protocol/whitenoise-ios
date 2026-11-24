import SwiftUI

/// Main app shell once at least one identity exists. A single Chats stack;
/// Settings and account switching are reached from the top-left avatar,
/// matching the Messages-app shape (no bottom tab bar).
struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // ChatsListView owns its own NavigationStack so it can drive
        // programmatic navigation (e.g. into a freshly created chat).
        ChatsListView()
            .sheet(item: Binding(
                get: { appState.pendingProfile },
                set: { if $0 == nil { appState.clearPendingProfile() } }
            )) { link in
                ProfileView(npub: link.npub)
                    .appAppearance()
            }
            // Link requests present themselves here, over any pushed screen.
            .sheet(item: Binding(
                get: { appState.deviceLinks.sheet },
                set: { if $0 == nil { appState.deviceLinks.sheetDismissed() } }
            )) { sheet in
                Group {
                    switch sheet {
                    case .approve(let promptID): DeviceLinkApprovalView(promptID: promptID)
                    case .linkThisDevice: NewDeviceLinkView()
                    case .addDevice: AddDeviceView()
                    }
                }
                .appAppearance()
            }
            .task(id: "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(appState.canUseLiveRuntime)") {
                await appState.deviceLinks.refresh(using: appState)
            }
    }
}

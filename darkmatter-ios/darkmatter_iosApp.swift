import SwiftUI

@main
struct darkmatter_iosApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    await appState.bootstrap()
                }
        }
    }
}

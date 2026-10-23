import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

/// Initial phase routing of a fresh `AppState`, before any runtime starts.
@MainActor
struct AppStatePhaseRoutingTests {
    @Test func freshAppStateStartsBootstrapping() async throws {
        let appState = AppState.test()
        #expect(appState.phase == .bootstrapping)
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeToast == nil)
    }
}

import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct AccountExitPresentationTests {
    @Test(arguments: [false, true])
    func sheetReceivesGateFailureWithoutDuplicateToast(wiping: Bool) async throws {
        let fixture = try isolatedState()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let state = fixture.state
        state.activeAccountRef = "unavailable-profile"
        var failures: [Toast] = []
        let result = wiping
            ? await state.signOutAndWipeActiveAccount(onError: { failures.append($0) })
            : await state.signOut(onError: { failures.append($0) })
        #expect(!result)
        #expect(failures.count == 1)
        #expect(state.activeToast == nil)
        #expect(state.activeAccountRef == "unavailable-profile")
    }

    @Test(arguments: [false, true])
    func callersWithoutInlineHandlerRetainFailureToast(wiping: Bool) async throws {
        let fixture = try isolatedState()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let state = fixture.state
        state.activeAccountRef = "unavailable-profile"
        let result = wiping
            ? await state.signOutAndWipeActiveAccount()
            : await state.signOut()
        #expect(!result)
        #expect(state.activeToast?.style == .error)
        state.dismissToast()
    }

    private func isolatedState() throws -> (state: AppState, defaults: UserDefaults, suite: String) {
        let suite = "AccountExitPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppState.test(accountDefaults: defaults, erasureDefaults: defaults), defaults, suite)
    }
}

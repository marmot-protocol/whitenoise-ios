import SwiftUI
import Testing
import UIKit
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

    @Test(arguments: [false, true])
    func partialReportKeepsThePresentedSheetAcrossAccountRouting(hasRemainingProfiles: Bool) async throws {
        let fixture = try isolatedState()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let state = fixture.state
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let host = UIHostingController(rootView: RootView()
            .environment(state)
            .environment(state.toastState)
            .environment(state.navigation)
            .environment(AppAppearanceStore(defaults: fixture.defaults, themeApplier: { _ in })))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        state.showSignOut = true
        try await waitUntil { host.presentedViewController != nil }
        let presenter = try #require(host.presentedViewController)
        try await waitUntil { !presenter.isBeingPresented }

        // Account routing removes Settings before the operation returns its report.
        state.setPhase(hasRemainingProfiles ? .ready : .onboarding)
        state.pendingWipeReport = WipeReport(stages: [
            WipeStageReport(stage: .deletingKeyPackages, completedCount: 0,
                            failures: [WipeFailureItem(subject: nil, reason: "Relay unavailable")]),
        ])
        state.showSignOut = false
        // Allow SwiftUI's presentation transaction and dismissal animation to settle.
        try await Task.sleep(for: .milliseconds(600))
        #expect(host.presentedViewController === presenter)
        #expect(state.pendingWipeReport != nil)

        state.pendingWipeReport = nil
        try await waitUntil { host.presentedViewController == nil }
        #expect(!state.showSignOut)
    }

    private func isolatedState() throws -> (state: AppState, defaults: UserDefaults, suite: String) {
        let suite = "AccountExitPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppState.test(accountDefaults: defaults, erasureDefaults: defaults), defaults, suite)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(predicate())
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import whitenoise_ios

// A live sheet needs exclusive use of the test host's window. Swift Testing's
// .serialized only serializes one suite, so its other window tests can interfere.
// XCTest runs these cases sequentially, outside the concurrent Swift Testing run.
@MainActor
final class AccountExitSheetTests: XCTestCase {
    func testPartialReportStaysVisibleAndClosesAboveWelcome() async throws {
        let fixtureReleased = try await checkPartialReport(hasRemainingProfiles: false)
        try await waitUntil("The Welcome fixture was not released", fixtureReleased)
    }

    func testPartialReportStaysVisibleAndClosesAboveProfileChooser() async throws {
        let fixtureReleased = try await checkPartialReport(hasRemainingProfiles: true)
        try await waitUntil("The profile chooser fixture was not released", fixtureReleased)
    }

    private func checkPartialReport(hasRemainingProfiles: Bool) async throws -> () -> Bool {
        let fixture = try isolatedState()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let state = fixture.state
        let appearance = AppAppearanceStore(defaults: fixture.defaults, themeApplier: { _ in })
        let lifetime = AccountExitFixtureLifetime(state: state, appearance: appearance)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let host = UIHostingController(rootView: RootView()
            .environment(state)
            .environment(state.toastState)
            .environment(state.navigation)
            .environment(appearance)
            .environment(\.accountExitFixtureLifetime, lifetime))
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
        try await waitUntil("Sign Out did not present") { host.presentedViewController != nil }
        let presenter = try XCTUnwrap(host.presentedViewController)
        try await waitUntil("Sign Out presentation did not finish") { !presenter.isBeingPresented }

        // Account routing removes Settings before the operation returns its report.
        state.setPhase(hasRemainingProfiles ? .ready : .onboarding)
        state.pendingWipeReport = WipeReport(stages: [
            WipeStageReport(stage: .deletingKeyPackages, completedCount: 0,
                            failures: [WipeFailureItem(subject: nil, reason: "Relay unavailable")]),
        ])
        state.showSignOut = false
        // Wait for the report itself to render, not an assumed animation duration.
        try await waitUntil("The wipe report did not replace Sign Out") {
            self.containsReport(in: presenter)
        }
        XCTAssertTrue(host.presentedViewController === presenter)
        XCTAssertNotNil(state.pendingWipeReport)

        state.pendingWipeReport = nil
        try await waitUntil("Closing the wipe report did not dismiss its sheet") {
            host.presentedViewController == nil
        }
        XCTAssertFalse(state.showSignOut)
        return { [weak state, weak appearance] in state == nil && appearance == nil }
    }

    private func isolatedState() throws -> (state: AppState, defaults: UserDefaults, suite: String) {
        let suite = "AccountExitSheetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppState.test(accountDefaults: defaults, erasureDefaults: defaults), defaults, suite)
    }

    private func containsReport(in controller: UIViewController) -> Bool {
        if let navigation = controller as? UINavigationController,
           navigation.navigationBar.topItem?.title == L10n.string("Sign Out & Wipe finished with issues") {
            return true
        }
        return controller.children.contains { containsReport(in: $0) }
    }

    private func waitUntil(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if !predicate() {
            XCTFail(message, file: file, line: line)
            throw PresentationTimeout()
        }
    }

    private struct PresentationTimeout: Error {}
}

// SwiftUI can release environment objects from an autorelease pool outside a
// Swift task. Older concurrency runtimes crash in isolated deinit on that path:
// https://github.com/swiftlang/swift/issues/88036
// Keep the fixture alive with its environment and release its final ownership
// inside a MainActor task. The tests also check that this does not leak it.
private final class AccountExitFixtureLifetime: Sendable {
    let state: AppState
    let appearance: AppAppearanceStore

    init(state: AppState, appearance: AppAppearanceStore) {
        self.state = state
        self.appearance = appearance
    }

    nonisolated deinit {
        Task { @MainActor [state, appearance] in
            withExtendedLifetime((state, appearance)) {}
        }
    }
}

private struct AccountExitFixtureLifetimeKey: EnvironmentKey {
    static let defaultValue: AccountExitFixtureLifetime? = nil
}

private extension EnvironmentValues {
    var accountExitFixtureLifetime: AccountExitFixtureLifetime? {
        get { self[AccountExitFixtureLifetimeKey.self] }
        set { self[AccountExitFixtureLifetimeKey.self] = newValue }
    }
}

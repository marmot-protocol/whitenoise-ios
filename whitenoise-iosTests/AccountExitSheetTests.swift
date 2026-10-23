import SwiftUI
import Testing
import UIKit
import XCTest
import MarmotKit
@testable import whitenoise_ios

// A live sheet needs exclusive use of the test host's window. Swift Testing's
// .serialized only serializes one suite, so its other window tests can interfere.
// XCTest runs these cases sequentially, outside the concurrent Swift Testing run.
@MainActor
final class AccountExitSheetTests: XCTestCase {
    func testPartialReportStaysVisibleAndClosesAboveWelcome() async throws {
        let fixtureReleased = try await checkPartialReport(intent: .signOut, hasRemainingProfiles: false)
        try await waitUntil("The Welcome fixture was not released", fixtureReleased)
    }

    func testPartialReportStaysVisibleAndClosesAboveProfileChooser() async throws {
        let fixtureReleased = try await checkPartialReport(intent: .signOut, hasRemainingProfiles: true)
        try await waitUntil("The profile chooser fixture was not released", fixtureReleased)
    }

    func testDeletionReportStaysVisibleAndClosesAboveWelcome() async throws {
        let fixtureReleased = try await checkPartialReport(intent: .deleteProfile, hasRemainingProfiles: false)
        try await waitUntil("The deletion Welcome fixture was not released", fixtureReleased)
    }

    func testDeletionReportStaysVisibleAndClosesAboveProfileChooser() async throws {
        let fixtureReleased = try await checkPartialReport(intent: .deleteProfile, hasRemainingProfiles: true)
        try await waitUntil("The deletion chooser fixture was not released", fixtureReleased)
    }

    private func checkPartialReport(
        intent: AccountExitIntent,
        hasRemainingProfiles: Bool
    ) async throws -> () -> Bool {
        let fixture = try isolatedState()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let state = fixture.state
        let appearance = AppAppearanceStore(defaults: fixture.defaults, themeApplier: { _ in })
        let lifetime = AccountExitFixtureLifetime(state: state, appearance: appearance)
        let host = UIHostingController(rootView: RootView()
            .environment(state)
            .environment(state.toastState)
            .environment(state.navigation)
            .environment(appearance)
            .environment(\.accountExitFixtureLifetime, lifetime))
        return try await withHostedWindow(host) { _ in
            defer { host.dismiss(animated: false) }
            state.accountExitIntent = intent
            var signOutPresenter: UIViewController?
            if intent == .signOut {
                try await waitUntil("Sign Out did not present") { host.presentedViewController != nil }
                signOutPresenter = host.presentedViewController
                try await waitUntil("Sign Out presentation did not finish") {
                    signOutPresenter?.isBeingPresented == false
                }
            }

            if hasRemainingProfiles {
                state.accountStore.accounts = [
                    AccountSummaryFfi(
                        label: "remaining-profile", accountIdHex: String(repeating: "a", count: 64),
                        localSigning: true, signedOut: false, running: false
                    ),
                ]
            }
            state.accountStore.requestProfileSelection()
            state.setPhase(hasRemainingProfiles ? .ready : .onboarding)
            state.pendingWipeReport = WipeReport(stages: [
                WipeStageReport(stage: .deletingKeyPackages, completedCount: 0,
                                failures: [WipeFailureItem(subject: nil, reason: "Relay unavailable")]),
            ])
            state.accountExitIntent = nil
            try await waitUntil("The cleanup report did not appear") {
                guard let presenter = host.presentedViewController else { return false }
                return self.containsTitle("Some cleanup couldn’t be completed", in: presenter)
            }
            let presenter = try XCTUnwrap(host.presentedViewController)
            if let signOutPresenter { XCTAssertTrue(presenter === signOutPresenter) }
            XCTAssertNotNil(state.pendingWipeReport)

            state.pendingWipeReport = nil
            if hasRemainingProfiles {
                try await waitUntil("Closing the report did not reveal profile selection") {
                    self.containsTitle("Choose a profile", in: presenter)
                }
                XCTAssertTrue(host.presentedViewController === presenter)
                // Leave selection to verify teardown without starting a real account.
                state.setPhase(.onboarding)
            }
            try await waitUntil("Account exit did not dismiss above Welcome") {
                host.presentedViewController == nil
            }
            XCTAssertNil(state.accountExitIntent)
            return { [weak state, weak appearance] in state == nil && appearance == nil }
        }
    }

    private func isolatedState() throws -> (state: AppState, defaults: UserDefaults, suite: String) {
        let suite = "AccountExitSheetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppState.test(accountDefaults: defaults, erasureDefaults: defaults), defaults, suite)
    }

    private func containsTitle(_ title: String.LocalizationValue, in controller: UIViewController) -> Bool {
        if let navigation = controller as? UINavigationController,
           navigation.navigationBar.topItem?.title == L10n.string(title) {
            return true
        }
        return controller.children.contains { containsTitle(title, in: $0) }
    }

    private func waitUntil(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) async throws {
        // UIKit reports presentation and release only through state, so this
        // polls, within the shared bounded budget rather than a local 4 s one.
        do {
            try await eventually { predicate() }
        } catch {
            XCTFail(message, file: file, line: line)
            throw error
        }
    }
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

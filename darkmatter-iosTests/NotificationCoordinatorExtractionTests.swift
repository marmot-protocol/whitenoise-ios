import Foundation
import Testing
@testable import darkmatter_ios

struct NotificationCoordinatorExtractionTests {
    @Test func notificationCoordinatorOwnsNotificationTaskState() throws {
        let coordinatorSource = try sourceString("darkmatter-ios/Core/NotificationCoordinator.swift")
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")

        #expect(coordinatorSource.matches(#"@MainActor\s+@Observable\s+final class NotificationCoordinator"#))
        #expect(coordinatorSource.contains("private let notificationDriver = NotificationDriver()"))
        #expect(coordinatorSource.contains("private var nativePushRegistrationTask: Task<Void, Never>?"))
        #expect(coordinatorSource.contains("private var isForegroundCatchUpRunning = false"))
        #expect(coordinatorSource.contains("private var notificationSubscriptionFailureToastPresented = false"))

        #expect(!appStateSource.contains("private let notificationDriver = NotificationDriver()"))
        #expect(!appStateSource.contains("private var nativePushRegistrationTask: Task<Void, Never>?"))
        #expect(!appStateSource.contains("private var isForegroundCatchUpRunning = false"))
        #expect(!appStateSource.contains("private var notificationSubscriptionFailureToastPresented = false"))
    }

    @Test func appStateNotificationEntrypointsForwardToCoordinator() throws {
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")

        #expect(appStateSource.contains("@ObservationIgnored let notificationCoordinator = NotificationCoordinator()"))
        #expect(appStateSource.matches(#"var notificationSubscriptionActive: Bool \{\s*notificationCoordinator\.notificationSubscriptionActive\s*\}"#))
        #expect(appStateSource.matches(#"func notificationSettings\(for accountRef: String\) async -> NotificationSettingsFfi\? \{\s*await notificationCoordinator\.notificationSettings\(for: accountRef, host: self\)\s*\}"#))
        #expect(appStateSource.matches(#"func setNativePushEnabled\(_ enabled: Bool\) async throws -> NotificationSettingsFfi \{\s*try await notificationCoordinator\.setNativePushEnabled\(enabled, host: self\)\s*\}"#))
        #expect(appStateSource.matches(#"func scheduleNativePushRegistrationIfEnabled\(\) \{\s*notificationCoordinator\.scheduleNativePushRegistrationIfEnabled\(host: self\)\s*\}"#))
        #expect(appStateSource.matches(#"func catchUpAfterForegroundActivation\(\) async \{\s*await notificationCoordinator\.catchUpAfterForegroundActivation\(host: self\)\s*\}"#))
    }

    @Test func notificationCoordinatorKeepsForegroundResumePushIndependentFromCatchUp() throws {
        let coordinatorSource = try sourceString("darkmatter-ios/Core/NotificationCoordinator.swift")
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")

        let catchUpStart = try #require(coordinatorSource.range(of: "func catchUpAfterForegroundActivation(host: NotificationCoordinatorHost) async {"))
        let catchUpEnd = try #require(coordinatorSource.range(of: "func setAppSceneActive", range: catchUpStart.upperBound..<coordinatorSource.endIndex))
        let catchUpBody = String(coordinatorSource[catchUpStart.lowerBound..<catchUpEnd.lowerBound])
        #expect(catchUpBody.contains("try await host.marmot.catchUpAccounts()"))
        #expect(!catchUpBody.contains("syncNativePushRegistrationIfEnabled"))

        let resumeStart = try #require(appStateSource.range(of: "func resumeAfterForegroundActivation() async {"))
        let resumeEnd = try #require(appStateSource.range(of: "private func noteRuntimeForegroundReadyAfterSuspension()"))
        let resumeBody = String(appStateSource[resumeStart.lowerBound..<resumeEnd.lowerBound])
        #expect(resumeBody.matches(
            #"await catchUpAfterForegroundActivation\(\)\s+"#
                + #"guard isAppSceneActive, !Task\.isCancelled else \{ return \}\s+"#
                + #"scheduleNativePushRegistrationIfEnabled\(\)\s+"#
                + #"resumeProfileFetchQueueIfNeeded\(\)"#
        ))
    }

    @Test func foregroundMaintenanceCancelsNativePushBeforeAwaitingForegroundTask() throws {
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")

        let cancelStart = try #require(appStateSource.range(of: "private func cancelForegroundMaintenance() async {"))
        let cancelEnd = try #require(appStateSource.range(of: "static func nativePushEnabledAccountRefs", range: cancelStart.upperBound..<appStateSource.endIndex))
        let cancelBody = appStateSource[cancelStart.lowerBound..<cancelEnd.lowerBound]

        let cancelNativePush = try #require(cancelBody.range(of: "notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()"))
        let awaitForeground = try #require(cancelBody.range(of: "await foregroundTask?.value"))
        let awaitNativePush = try #require(cancelBody.range(of: "await notificationCoordinator.cancelNativePushRegistrationTask()"))

        #expect(cancelNativePush.lowerBound < awaitForeground.lowerBound)
        #expect(awaitForeground.lowerBound < awaitNativePush.lowerBound)
    }

    @Test func notificationCoordinatorHostHidesConcreteAppStateWiring() throws {
        let coordinatorSource = try sourceString("darkmatter-ios/Core/NotificationCoordinator.swift")
        let appStateSource = try sourceString("darkmatter-ios/Core/AppState.swift")

        #expect(!coordinatorSource.contains("appStateForNotifications"))
        #expect(!coordinatorSource.contains("func cancel()"))
        #expect(coordinatorSource.contains("func configureNotifications()"))
        #expect(coordinatorSource.contains("host.configureNotifications()"))
        #expect(appStateSource.contains("func configureNotifications()"))
        #expect(appStateSource.contains("notifications.configure(appState: self)"))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}

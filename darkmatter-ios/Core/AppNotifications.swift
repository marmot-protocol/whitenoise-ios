import Foundation
import UIKit
import UserNotifications
import MarmotKit

@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    private let center: UNUserNotificationCenter
    private weak var appState: AppState?
    private var pendingRoutes: [LocalNotificationRoute] = []

    private(set) var apnsTokenHex: String?
    private(set) var lastRegistrationError: String?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func installDelegate() {
        center.delegate = self
    }

    func configure(appState: AppState) {
        self.appState = appState
        installDelegate()
        flushPendingRoutes()
    }

    func requestAuthorizationAndRegister() async throws -> Bool {
        let granted = try await requestAuthorization()
        if granted {
            registerForRemoteNotifications()
        }
        return granted
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    @discardableResult
    func registerForRemoteNotificationsIfAuthorized() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            registerForRemoteNotifications()
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    func recordDeviceToken(_ deviceToken: Data) {
        apnsTokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastRegistrationError = nil
        Task { [weak self] in
            await self?.appState?.syncNativePushRegistrationIfEnabled()
        }
    }

    func recordRegistrationFailure(_ error: Error) {
        lastRegistrationError = error.localizedDescription
    }

    func present(update: NotificationUpdateFfi) async {
        guard let presentation = LocalNotificationProjection.makePresentation(for: update) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        content.threadIdentifier = presentation.threadIdentifier
        content.userInfo = presentation.userInfo

        let request = UNNotificationRequest(
            identifier: presentation.identifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            appState?.present(.error("Notification failed", message: error.localizedDescription))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if let route = LocalNotificationProjection.route(
            from: notification.request.content.userInfo
        ), appState?.isViewingNotificationDestination(
            accountRef: route.accountRef,
            groupIdHex: route.groupIdHex
        ) == true {
            return []
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = LocalNotificationProjection.route(
            from: response.notification.request.content.userInfo
        ) else { return }
        handle(route: route)
    }

    private func handle(route: LocalNotificationRoute) {
        guard let appState else {
            pendingRoutes.append(route)
            return
        }
        appState.presentNotification(route: route)
    }

    private func flushPendingRoutes() {
        guard let appState, !pendingRoutes.isEmpty else { return }
        for route in pendingRoutes {
            appState.presentNotification(route: route)
        }
        pendingRoutes.removeAll()
    }
}

enum NotificationSettingsActionError: LocalizedError {
    case noActiveAccount
    case permissionDenied
    case nativePushNotConfigured
    case missingApnsToken

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return "No active account."
        case .permissionDenied:
            return "Notifications are disabled in system settings."
        case .nativePushNotConfigured:
            return "Native push server configuration is missing."
        case .missingApnsToken:
            return "APNS has not returned a device token yet."
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppNotifications.shared.installDelegate()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppNotifications.shared.recordDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppNotifications.shared.recordRegistrationFailure(error)
    }
}

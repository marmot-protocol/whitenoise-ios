import Foundation
import UIKit
import UserNotifications
import MarmotKit

@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    private let center: UNUserNotificationCenter
    private let requestAuthorizationHandler: (() async throws -> Bool)?
    private let authorizationStatusProvider: (() async -> UNAuthorizationStatus)?
    private let remoteNotificationRegistrar: (() -> Void)?
    private weak var appState: AppState?
    private var pendingRoutes: [LocalNotificationRoute] = []

    private(set) var apnsTokenHex: String?
    private(set) var lastRegistrationError: String?

    init(
        center: UNUserNotificationCenter = .current(),
        requestAuthorizationHandler: (() async throws -> Bool)? = nil,
        authorizationStatusProvider: (() async -> UNAuthorizationStatus)? = nil,
        remoteNotificationRegistrar: (() -> Void)? = nil
    ) {
        self.center = center
        self.requestAuthorizationHandler = requestAuthorizationHandler
        self.authorizationStatusProvider = authorizationStatusProvider
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
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
        if let requestAuthorizationHandler {
            return try await requestAuthorizationHandler()
        }
        return try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        if let authorizationStatusProvider {
            return await authorizationStatusProvider()
        }
        return await center.notificationSettings().authorizationStatus
    }

    func registerForRemoteNotifications() {
        if let remoteNotificationRegistrar {
            remoteNotificationRegistrar()
            return
        }
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
        appState?.scheduleNativePushRegistrationIfEnabled()
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
            appState?.present(.error(L10n.string("Notification failed"), message: error.localizedDescription))
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

    /// Notification taps that arrive before `appState` is wired up are buffered.
    /// Bound the buffer so a notification flood during startup can't grow memory
    /// unboundedly; keep the most recent routes (#18).
    static let maxPendingRoutes = 32

    nonisolated static func appendingBounded<T>(_ element: T, to array: [T], limit: Int) -> [T] {
        var next = array
        next.append(element)
        if next.count > limit {
            next.removeFirst(next.count - limit)
        }
        return next
    }

    private func handle(route: LocalNotificationRoute) {
        guard let appState else {
            pendingRoutes = Self.appendingBounded(route, to: pendingRoutes, limit: Self.maxPendingRoutes)
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
            return L10n.string("No active account.")
        case .permissionDenied:
            return L10n.string("Notifications are disabled in system settings.")
        case .nativePushNotConfigured:
            return L10n.string("Native push server configuration is missing.")
        case .missingApnsToken:
            return L10n.string("APNS has not returned a device token yet.")
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

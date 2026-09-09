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
    private let applicationBadgeCountSetter: ((Int) async throws -> Void)?
    private let deliveredNotificationDescriptorsProvider:
        (() async -> [DeliveredNotificationDescriptor])?
    private let deliveredNotificationIdentifiersRemover: (([String]) -> Void)?
    private weak var appState: AppState?
    private var pendingRoutes: [LocalNotificationRoute] = []
    private var pendingActionOperations: [NotificationActionOperation] = []
    private var actionOperationTask: Task<Void, Never>?
    private var applicationBadgeUpdateTask: Task<Void, Never>?
    private var languageChangeObserver: (any NSObjectProtocol)?

    private(set) var apnsTokenHex: String?
    private(set) var lastRegistrationError: String?

    init(
        center: UNUserNotificationCenter = .current(),
        requestAuthorizationHandler: (() async throws -> Bool)? = nil,
        authorizationStatusProvider: (() async -> UNAuthorizationStatus)? = nil,
        remoteNotificationRegistrar: (() -> Void)? = nil,
        applicationBadgeCountSetter: ((Int) async throws -> Void)? = nil,
        deliveredNotificationDescriptorsProvider:
            (() async -> [DeliveredNotificationDescriptor])? = nil,
        deliveredNotificationIdentifiersRemover: (([String]) -> Void)? = nil
    ) {
        self.center = center
        self.requestAuthorizationHandler = requestAuthorizationHandler
        self.authorizationStatusProvider = authorizationStatusProvider
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.applicationBadgeCountSetter = applicationBadgeCountSetter
        self.deliveredNotificationDescriptorsProvider = deliveredNotificationDescriptorsProvider
        self.deliveredNotificationIdentifiersRemover = deliveredNotificationIdentifiersRemover
        super.init()
    }

    func installDelegate() {
        center.delegate = self
        registerNotificationCategories()
        guard languageChangeObserver == nil else { return }
        // Action titles are baked into the registered category; re-register on
        // in-app language changes so they don't stay in the launch language.
        languageChangeObserver = NotificationCenter.default.addObserver(
            forName: AppLanguage.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.registerNotificationCategories()
            }
        }
    }

    func configure(appState: AppState) {
        self.appState = appState
        installDelegate()
        flushPendingRoutes()
        flushPendingActionOperations()
    }

    func registerNotificationCategories() {
        center.setNotificationCategories([Self.messageNotificationCategory()])
    }

    static func messageNotificationCategory() -> UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: NotificationActionCategory.replyActionIdentifier,
            title: L10n.string("Reply"),
            options: [],
            textInputButtonTitle: L10n.string("Send"),
            textInputPlaceholder: L10n.string("Message")
        )
        let markRead = UNNotificationAction(
            identifier: NotificationActionCategory.markReadActionIdentifier,
            title: L10n.string("Mark as read"),
            options: []
        )
        return UNNotificationCategory(
            identifier: NotificationActionCategory.message,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: []
        )
    }

    func requestAuthorizationAndRegister() async throws -> Bool {
        let granted = try await requestAuthorization()
        if granted {
            registerForRemoteNotifications()
        }
        return granted
    }

    func requestAuthorization() async throws -> Bool {
        let recorder = appState?.productAnalytics
        let ticket = recorder?.ticket()
        let granted: Bool
        if let requestAuthorizationHandler {
            granted = try await requestAuthorizationHandler()
        } else {
            granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        let status = await authorizationStatus()
        let outcome: ProductPermissionOutcome?
        switch status {
        case .authorized: outcome = .granted
        case .denied: outcome = .denied
        case .provisional, .ephemeral: outcome = .provisional
        case .notDetermined: outcome = nil
        @unknown default: outcome = nil
        }
        if let outcome { recorder?.record(.permission(outcome), ticket: ticket) }
        return granted
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

    /// Serializes app-icon badge writes so an older asynchronous system call
    /// can never land after a newer unread projection and restore a stale count.
    @discardableResult
    func scheduleApplicationBadgeCount(_ count: Int) -> Task<Void, Never> {
        let previous = applicationBadgeUpdateTask
        let center = center
        let applicationBadgeCountSetter = applicationBadgeCountSetter
        let boundedCount = max(count, 0)
        let task = Task { @MainActor in
            await previous?.value
            do {
                if let applicationBadgeCountSetter {
                    try await applicationBadgeCountSetter(boundedCount)
                } else {
                    try await center.setBadgeCount(boundedCount)
                }
            } catch {
                // A disabled system Badges setting is not an application error.
                // The next unread-state mutation retries the authoritative count.
            }
        }
        applicationBadgeUpdateTask = task
        return task
    }

    func setApplicationBadgeCount(_ count: Int) async {
        await scheduleApplicationBadgeCount(count).value
    }

    func drainApplicationBadgeUpdates() async {
        await applicationBadgeUpdateTask?.value
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

    /// Clears the cached APNS token and asks iOS for a fresh one. Waits until
    /// the app delegate receives a token, registration fails, or the timeout
    /// elapses. A successful refresh schedules native push re-registration.
    func refreshApnsToken(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        pollIntervalNanoseconds: UInt64 = 100_000_000
    ) async throws -> String {
        guard await registerForRemoteNotificationsIfAuthorized() else {
            throw NotificationSettingsActionError.permissionDenied
        }

        apnsTokenHex = nil
        lastRegistrationError = nil
        registerForRemoteNotifications()

        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let errorMessage = lastRegistrationError {
                throw NotificationSettingsActionError.apnsRegistrationFailed(errorMessage)
            }
            if let token = apnsTokenHex, !token.isEmpty {
                return token
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        if let errorMessage = lastRegistrationError {
            throw NotificationSettingsActionError.apnsRegistrationFailed(errorMessage)
        }
        throw NotificationSettingsActionError.apnsTokenRefreshTimedOut
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
        // A private contact nickname (App-Group-backed, owner→contact keyed)
        // overrides the kind:0 sender name in the foreground-presented alert,
        // matching what the in-app UI and the NSE render.
        guard let presentation = LocalNotificationProjection.makePresentation(
            for: update,
            nickname: { ownerAccountIdHex, contactAccountIdHex in
                ContactNicknameStore.nickname(
                    ownerAccountIdHex: ownerAccountIdHex,
                    contactAccountIdHex: contactAccountIdHex
                )
            }
        ) else {
            return
        }

        // The banner is enqueued immediately; a cold avatar warms the cache
        // for the sender's next message instead of delaying this one.
        let avatarData = NotificationCommunicationDecorator.cachedAvatarData(
            forPictureUrl: presentation.senderPictureUrl
        )
        if avatarData == nil {
            NotificationCommunicationDecorator.warmAvatarCache(for: presentation.senderPictureUrl)
        }
        let content = NotificationCommunicationDecorator.decorated(
            NotificationContentDecorator.makeContent(for: presentation),
            presentation: presentation,
            avatarData: avatarData
        )

        let request = UNNotificationRequest(
            identifier: presentation.identifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            appState?.present(.error(
                L10n.string("Notification failed"),
                message: L10n.string("We'll keep trying in the background.")
            ))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if LocalNotificationProjection.isActionFailure(from: userInfo) {
            return [.banner, .list, .sound]
        }
        if LocalNotificationProjection.isQuietOrFallback(from: userInfo) {
            return []
        }
        if let route = LocalNotificationProjection.route(from: userInfo) {
            let localNotificationsEnabled = await appState?.client?
                .localNotificationsEnabledForPresentation(accountRef: route.accountRef) ?? true
            let isArchived = await routeIsArchived(route)
            guard NotificationPresentationPolicy.shouldPresent(
                localNotificationsEnabled: localNotificationsEnabled,
                isArchived: isArchived,
                notifyMode: routeNotifyMode(route, userInfo: userInfo),
                isMention: LocalNotificationProjection.isMention(
                    from: notification.request.content.userInfo
                ),
                appSceneActive: appState?.isAppSceneActive ?? true,
                updateAccountRef: route.accountRef,
                updateGroupIdHex: route.groupIdHex,
                visibleAccountRef: appState?.visibleChat?.accountRef,
                visibleGroupIdHex: appState?.visibleChat?.groupIdHex
            ) else {
                return []
            }
        }
        return [.banner, .list, .sound]
    }

    /// Archived chats shed notification attention; a missing client or
    /// failed read fails open (presents).
    private func routeIsArchived(_ route: LocalNotificationRoute) async -> Bool {
        guard let client = appState?.client,
              let row = try? await client.chatListRow(
                  accountRef: route.accountRef,
                  groupIdHex: route.groupIdHex
              )
        else { return false }
        return row.archived
    }

    /// Resolve the mute key from the account id persisted with the notification.
    /// Missing pre-upgrade metadata fails safe so a signed-out/missing account
    /// cannot become audibly unmuted.
    private func routeNotifyMode(
        _ route: LocalNotificationRoute,
        userInfo: [AnyHashable: Any]
    ) -> ChatNotifyMode {
        guard let accountIdHex = LocalNotificationProjection.accountIdHex(from: userInfo) else {
            return .nothing
        }
        return ChatMuteStore.notifyMode(accountIdHex: accountIdHex, groupIdHex: route.groupIdHex)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = LocalNotificationProjection.route(
            from: response.notification.request.content.userInfo
        ) else { return }
        guard let operation = NotificationActionRouting.operation(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText,
            route: route
        ) else { return }
        switch operation {
        case .openChat(let route):
            appState?.productActivation(.foregroundNotification)
            handle(route: route)
        case .reply, .markRead:
            // Await completion: returning from the async delegate method ends
            // the system's response-handling grace period.
            await performOrBufferAction(operation)
        }
    }

    /// Notification taps that arrive before `appState` is wired up are buffered.
    /// Bound the buffer so a notification flood during startup can't grow memory
    /// unboundedly; keep the most recent routes (#18).
    nonisolated static let maxPendingRoutes = 32

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
        appState.productActivation(.foregroundNotification)
        for route in pendingRoutes {
            appState.presentNotification(route: route)
        }
        pendingRoutes.removeAll()
    }

    private func performOrBufferAction(_ operation: NotificationActionOperation) async {
        guard let appState else {
            pendingActionOperations = Self.appendingBounded(
                operation,
                to: pendingActionOperations,
                limit: Self.maxPendingRoutes
            )
            return
        }
        await enqueueActionOperations([operation], appState: appState).value
    }

    private func flushPendingActionOperations() {
        guard let appState, !pendingActionOperations.isEmpty else { return }
        let operations = pendingActionOperations
        pendingActionOperations.removeAll()
        _ = enqueueActionOperations(operations, appState: appState)
    }

    /// Serializes reply/mark-read work so two responses can't interleave two
    /// runtime restart/suspend cycles over the same App Group store.
    private func enqueueActionOperations(
        _ operations: [NotificationActionOperation],
        appState: AppState
    ) -> Task<Void, Never> {
        let previousTask = actionOperationTask
        let task = Task { @MainActor in
            await previousTask?.value
            for operation in operations {
                await appState.performNotificationAction(operation)
            }
        }
        actionOperationTask = task
        return task
    }

    /// Visible failure surface for a notification action: a toast is invisible
    /// while backgrounded, so post a local notification carrying the
    /// conversation route; fall back to a toast when the scene is active (or
    /// when posting fails). Bodies stay generic — no backend error text.
    func presentNotificationActionFailure(
        title: String,
        body: String,
        route: LocalNotificationRoute
    ) async {
        if appState?.isAppSceneActive == true {
            appState?.present(.error(title, message: body))
            return
        }
        let presentation = LocalNotificationPresentation(
            identifier: "action-failure:\(route.notificationKey)",
            threadIdentifier: "\(route.accountRef):\(route.groupIdHex)",
            title: title,
            body: body,
            route: route,
            timestamp: Date(),
            userInfo: LocalNotificationProjection.userInfo(for: route).merging(
                [
                    LocalNotificationProjection.deliveryDispositionKey:
                        LocalNotificationProjection.actionFailureDisposition,
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        let request = UNNotificationRequest(
            identifier: presentation.identifier,
            content: NotificationContentDecorator.makeContent(for: presentation),
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            appState?.present(.error(title, message: body))
        }
    }

    /// Dismiss only the notification whose action succeeded. Sibling messages
    /// in the same conversation may still represent unread content.
    func removeDeliveredNotification(identifier: String) {
        center.removeDeliveredNotifications(
            withIdentifiers: NotificationActionDeliveredNotificationPolicy.identifiersToRemove(
                actedNotificationIdentifier: identifier
            )
        )
    }

    /// Reconciles Notification Center only after MDK confirms a read-marker
    /// mutation. A fully read chat sheds its whole delivered message stack;
    /// a partially read chat sheds only notifications for the messages that
    /// actually advanced the marker, preserving newer unread attention.
    func reconcileDeliveredNotificationsAfterRead(
        accountRef: String,
        groupIdHex: String,
        readMessageIdHexes: Set<String>,
        conversationStillHasUnread: Bool?
    ) async {
        guard !readMessageIdHexes.isEmpty else { return }
        let descriptors = await deliveredNotificationDescriptors()
        let identifiers = DeliveredNotificationReadCleanupPolicy.identifiersToRemove(
            from: descriptors,
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            readMessageIdHexes: readMessageIdHexes,
            removeEntireConversation: conversationStillHasUnread == false
        )
        guard !identifiers.isEmpty else { return }
        if let deliveredNotificationIdentifiersRemover {
            deliveredNotificationIdentifiersRemover(identifiers)
        } else {
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func deliveredNotificationDescriptors() async -> [DeliveredNotificationDescriptor] {
        if let deliveredNotificationDescriptorsProvider {
            return await deliveredNotificationDescriptorsProvider()
        }
        let delivered = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
        return delivered.map { notification in
            let content = notification.request.content
            return DeliveredNotificationDescriptor(
                identifier: notification.request.identifier,
                route: LocalNotificationProjection.route(from: content.userInfo),
                isMessageNotification: content.categoryIdentifier
                    == NotificationActionCategory.message,
                isActionFailure: LocalNotificationProjection.isActionFailure(
                    from: content.userInfo
                )
            )
        }
    }
}

nonisolated struct DeliveredNotificationDescriptor: Equatable {
    let identifier: String
    let route: LocalNotificationRoute?
    let isMessageNotification: Bool
    let isActionFailure: Bool
}

nonisolated enum DeliveredNotificationReadCleanupPolicy {
    static func identifiersToRemove(
        from notifications: [DeliveredNotificationDescriptor],
        accountRef: String,
        groupIdHex: String,
        readMessageIdHexes: Set<String>,
        removeEntireConversation: Bool
    ) -> [String] {
        notifications.compactMap { notification in
            guard notification.isMessageNotification,
                  !notification.isActionFailure,
                  let route = notification.route,
                  route.accountRef == accountRef,
                  route.groupIdHex == groupIdHex
            else { return nil }
            if removeEntireConversation {
                return notification.identifier
            }
            guard let messageIdHex = route.messageIdHex,
                  readMessageIdHexes.contains(messageIdHex)
            else { return nil }
            return notification.identifier
        }
    }
}

nonisolated enum NotificationActionDeliveredNotificationPolicy {
    static func identifiersToRemove(actedNotificationIdentifier: String) -> [String] {
        [actedNotificationIdentifier]
    }
}

enum NotificationSettingsActionError: LocalizedError {
    case noActiveAccount
    case permissionDenied
    case nativePushNotConfigured
    case missingApnsToken
    case apnsTokenRefreshTimedOut
    case apnsRegistrationFailed(String)

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
        case .apnsTokenRefreshTimedOut:
            return L10n.string("APNS did not return a new device token in time. Try again, or check notification permission in Settings.")
        case let .apnsRegistrationFailed(message):
            return L10n.formatted("APNS registration failed: %@", message)
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

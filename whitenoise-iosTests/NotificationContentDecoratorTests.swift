import Foundation
import Testing
import UserNotifications
@testable import whitenoise_ios

struct NotificationContentDecoratorTests {
    private func presentation() -> LocalNotificationPresentation {
        notificationPresentation(userInfo: ["k": "v"])
    }

    @Test func applyRendersAudibleContentByDefaultAndMergesUserInfo() {
        let content = UNMutableNotificationContent()
        content.userInfo = ["existing": "keep"]

        NotificationContentDecorator.apply(presentation(), to: content)

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.userInfo["existing"] as? String == "keep")
        #expect(content.userInfo["k"] as? String == "v")
    }

    @Test func makeContentAppliesSameDecorationOnFreshContent() {
        let content = NotificationContentDecorator.makeContent(
            for: presentation(),
            applicationBadgeCount: 7
        )

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == UNNotificationSound.default)
        #expect(content.interruptionLevel == .active)
        #expect(content.userInfo["k"] as? String == "v")
        #expect(content.badge == 7)
    }

    @Test func quietContentKeepsItsThreadAndBadgeWithoutSoundOrInterruption() {
        let content = NotificationContentDecorator.makeContent(
            for: presentation(),
            applicationBadgeCount: 7,
            alerting: .quiet
        )

        #expect(content.title == "Alice")
        #expect(content.body == "hello")
        #expect(content.threadIdentifier == "thread-1")
        #expect(content.targetContentIdentifier == "id-1")
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
        #expect(content.userInfo["k"] as? String == "v")
        #expect(content.badge == 7)
    }

    @Test func quietAlertingSilencesContentThatArrivedWithASound() {
        let content = UNMutableNotificationContent()
        content.sound = .default

        NotificationContentDecorator.applyAlerting(.quiet, to: content)

        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
    }

    @Test func communicationDecorationPreservesQuietAlerting() {
        var notification = presentation()
        notification.senderName = "Alice"
        notification.senderAccountIdHex = "alice-id"
        let content = NotificationContentDecorator.makeContent(
            for: notification,
            alerting: .quiet
        )

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: notification,
            avatarData: nil
        )

        #expect(decorated.sound == nil)
        #expect(decorated.interruptionLevel == .passive)
    }

    @Test func zeroApplicationBadgeClearsTheIconCount() {
        let content = UNMutableNotificationContent()
        content.badge = 9

        NotificationContentDecorator.applyApplicationBadgeCount(0, to: content)

        #expect(content.badge == 0)
    }

    @Test func communicationDecorationPreservesApplicationBadge() {
        var notification = presentation()
        notification.senderName = "Alice"
        notification.senderAccountIdHex = "alice-id"
        let content = NotificationContentDecorator.makeContent(
            for: notification,
            applicationBadgeCount: 6
        )

        let decorated = NotificationCommunicationDecorator.decorated(
            content,
            presentation: notification,
            avatarData: nil
        )

        #expect(decorated.badge == 6)
    }

    @Test func timeoutFallbackAppliesOnlyWhenNoRenderDecisionWasApplied() {
        #expect(NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: true,
            didApplyRenderDecision: false
        ))
        #expect(!NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: true,
            didApplyRenderDecision: true
        ))
        #expect(!NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: false,
            didApplyRenderDecision: false
        ))
    }

    @Test func timeoutDeliveryWaitsForExpirationCleanup() {
        #expect(NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: false,
            completingExpiration: false
        ))
        #expect(!NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: true,
            completingExpiration: false
        ))
        #expect(NotificationServiceTimeoutPolicy.canDeliver(
            expirationInProgress: true,
            completingExpiration: true
        ))
    }

    /// The extension can't drop the alert that woke it, so a wake with no local
    /// presentation still says something: never a blank notification.
    @Test(arguments: ["", "   ", "\n"])
    func fallbackFillsBlankCopyWithTheGenericTitleAndBody(_ blank: String) {
        let content = pushContent(title: blank, body: blank)

        NotificationContentDecorator.applyFallback(to: content)

        // The same title and body generic preview mode delivers.
        let generic = LocalNotificationProjection.genericContentText()
        #expect(content.title == generic.title)
        #expect(content.body == generic.body)
        #expect(!content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
        expectStillAlertsWithPushData(content)
    }

    /// Only a blank field is replaced; copy the push already carries stays, and
    /// the wake is still marked as a fallback so the foreground app won't
    /// present it again.
    @Test(arguments: [("Server title", ""), ("", "Server body"), ("Server title", "Server body")])
    func fallbackReplacesOnlyBlankFields(title: String, body: String) {
        let content = pushContent(title: title, body: body)

        NotificationContentDecorator.applyFallback(to: content)

        let generic = LocalNotificationProjection.genericContentText()
        #expect(content.title == (title.isEmpty ? generic.title : title))
        #expect(content.body == (body.isEmpty ? generic.body : body))
        #expect(content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.fallbackDisposition)
        expectStillAlertsWithPushData(content)
    }

    /// Push content as it reaches the extension: audible, with its own userInfo.
    private func pushContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = ["push": "data"]
        return content
    }

    /// Unlike quiet delivery, a fallback still alerts and keeps what the push carried.
    private func expectStillAlertsWithPushData(_ content: UNMutableNotificationContent) {
        #expect(content.sound != nil)
        #expect(content.interruptionLevel == .active)
        #expect(content.userInfo["push"] as? String == "data")
    }

    /// A fully muted wake keeps its copy (generic when blank) and the push's
    /// data, but lands silently in Notification Center: no sound, no banner.
    @Test(arguments: [("", ""), ("Server title", "Server body")])
    func quietDeliveryKeepsCopyButIsSilent(title: String, body: String) {
        let content = pushContent(title: title, body: body)

        NotificationContentDecorator.applyQuietDelivery(to: content)

        let generic = LocalNotificationProjection.genericContentText()
        #expect(content.title == (title.isEmpty ? generic.title : title))
        #expect(content.body == (body.isEmpty ? generic.body : body))
        #expect(content.userInfo["push"] as? String == "data")
        #expect(content.sound == nil)
        #expect(content.interruptionLevel == .passive)
        #expect(content.userInfo[LocalNotificationProjection.deliveryDispositionKey] as? String
            == LocalNotificationProjection.quietDisposition)
    }

    @Test func clearAvatarCacheRemovesLegacyAppGroupDirectoryAndHandlesAbsenceAndErrors() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationAvatarClearTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let fileManager = NotificationAvatarStubFileManager(sharedContainerURL: container)
        let avatarDir = container.appendingPathComponent("Library/Caches/NotificationAvatars", isDirectory: true)

        // Missing App Group container reports incomplete cleanup rather than success.
        let unavailableContainer = NotificationAvatarStubFileManager(sharedContainerURL: nil)
        #expect(!NotificationCommunicationDecorator.clearAvatarCache(fileManager: unavailableContainer))

        // Absent directory succeeds cleanly.
        #expect(NotificationCommunicationDecorator.clearAvatarCache(fileManager: fileManager))

        // Historical pre-upgrade cached avatar file is deleted on clear.
        try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        let cachedAvatar = avatarDir.appendingPathComponent("legacy-avatar")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cachedAvatar)
        #expect(FileManager.default.fileExists(atPath: cachedAvatar.path))

        #expect(NotificationCommunicationDecorator.clearAvatarCache(fileManager: fileManager))
        #expect(!FileManager.default.fileExists(atPath: avatarDir.path))

        // Removal error reports false so destructive wipes surface leftover data.
        try FileManager.default.createDirectory(at: avatarDir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: cachedAvatar)
        let failingManager = NotificationAvatarStubFileManager(
            sharedContainerURL: container,
            removeError: CocoaError(.fileWriteNoPermission)
        )
        #expect(!NotificationCommunicationDecorator.clearAvatarCache(fileManager: failingManager))
        #expect(FileManager.default.fileExists(atPath: avatarDir.path))
    }
}

private final class NotificationAvatarStubFileManager: FileManager {
    private let sharedContainerURL: URL?
    private let removeError: Error?

    init(sharedContainerURL: URL?, removeError: Error? = nil) {
        self.sharedContainerURL = sharedContainerURL
        self.removeError = removeError
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        sharedContainerURL
    }

    override func removeItem(at URL: URL) throws {
        if let removeError { throw removeError }
        try super.removeItem(at: URL)
    }
}

import Foundation
import UserNotifications

enum NotificationContentDecorator {
    static func apply(
        _ presentation: LocalNotificationPresentation,
        to content: UNMutableNotificationContent
    ) {
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        content.threadIdentifier = presentation.threadIdentifier
        var userInfo = content.userInfo
        for (key, value) in presentation.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
    }

    static func makeContent(
        for presentation: LocalNotificationPresentation
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        apply(presentation, to: content)
        return content
    }
}

import Foundation
@testable import whitenoise_ios

func notificationPresentation(
    identifier: String = "id-1",
    threadIdentifier: String = "thread-1",
    title: String = "Alice",
    body: String = "hello",
    senderPictureUrl: String? = nil,
    userInfo: [String: String] = [:]
) -> LocalNotificationPresentation {
    var presentation = LocalNotificationPresentation(
        identifier: identifier,
        threadIdentifier: threadIdentifier,
        title: title,
        body: body,
        route: LocalNotificationRoute(
            accountRef: "acct",
            groupIdHex: "group",
            notificationKey: "key",
            messageIdHex: "msg"
        ),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        userInfo: userInfo
    )
    presentation.senderPictureUrl = senderPictureUrl
    return presentation
}

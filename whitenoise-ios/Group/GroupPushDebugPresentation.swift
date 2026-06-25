import Foundation
import MarmotKit

enum GroupPushDebugPresentation {
    static func tokenSummary(for info: GroupPushDebugInfoFfi) -> String {
        [
            count(info.totalTokenCount, singular: "total", plural: "total"),
            count(info.activeTokenCount, singular: "active", plural: "active"),
            count(info.staleTokenCount, singular: "stale", plural: "stale")
        ].joined(separator: ", ")
    }

    static func missingRelayHintSummary(for info: GroupPushDebugInfoFfi) -> String {
        count(info.missingRelayHintCount, singular: "missing relay hint", plural: "missing relay hints")
    }

    static func localRegistrationSummary(for registration: LocalPushRegistrationDebugFfi) -> String {
        [
            registration.registered ? "Registered" : "Not registered",
            registration.nativePushEnabled ? "native push on" : "native push off",
            registration.localTokenCached ? "token cached" : "no local token"
        ].joined(separator: ", ")
    }

    static func platformLabel(_ platform: PushPlatformFfi) -> String {
        switch platform {
        case .apns:
            "APNS"
        case .fcm:
            "FCM"
        }
    }

    private static func count(_ value: UInt32, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

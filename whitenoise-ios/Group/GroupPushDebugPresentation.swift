import Foundation
import MarmotKit

enum GroupPushDebugPresentation {
    static func tokenSummary(
        for info: GroupPushDebugInfoFfi,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        join(
            join(
                L10n.plural("%llu total", UInt64(info.totalTokenCount), locale: locale),
                L10n.plural("%llu active", UInt64(info.activeTokenCount), locale: locale),
                locale: locale
            ),
            L10n.plural("%llu stale", UInt64(info.staleTokenCount), locale: locale),
            locale: locale
        )
    }

    static func missingRelayHintSummary(
        for info: GroupPushDebugInfoFfi,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        L10n.plural("%llu missing relay hints", UInt64(info.missingRelayHintCount), locale: locale)
    }

    static func localRegistrationSummary(
        for registration: LocalPushRegistrationDebugFfi,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        join(
            join(
                text(registration.registered ? "Registered" : "Not registered", locale: locale),
                text(registration.nativePushEnabled ? "native push on" : "native push off", locale: locale),
                locale: locale
            ),
            text(registration.localTokenCached ? "token cached" : "no local token", locale: locale),
            locale: locale
        )
    }

    static func platformLabel(_ platform: PushPlatformFfi) -> String {
        switch platform {
        case .apns:
            "APNS"
        case .fcm:
            "FCM"
        }
    }

    private static func join(_ first: String, _ second: String, locale: Locale) -> String {
        L10n.formatted("%@, %@", arguments: [first, second], locale: locale)
    }

    private static func text(_ value: String.LocalizationValue, locale: Locale) -> String {
        L10n.formatted(value, arguments: [], locale: locale)
    }
}

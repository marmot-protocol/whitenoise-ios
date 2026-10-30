import Testing
import Foundation
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupPushDebugPresentationTests {
    private func info(
        total: UInt32 = 0,
        active: UInt32 = 0,
        stale: UInt32 = 0,
        missingRelayHints: UInt32 = 0
    ) -> GroupPushDebugInfoFfi {
        GroupPushDebugInfoFfi(
            totalTokenCount: total,
            activeTokenCount: active,
            staleTokenCount: stale,
            missingRelayHintCount: missingRelayHints,
            lastTokenListUpdatedAtMs: nil,
            localRegistration: registration(registered: false, nativePush: false, tokenCached: false),
            tokens: []
        )
    }

    private func registration(
        registered: Bool,
        nativePush: Bool,
        tokenCached: Bool
    ) -> LocalPushRegistrationDebugFfi {
        // The fields the summary doesn't show take the opposite of
        // `registered`, so reading one of them instead fails.
        LocalPushRegistrationDebugFfi(
            registered: registered,
            shareable: !registered,
            localNotificationsEnabled: !registered,
            nativePushEnabled: nativePush,
            localLeafIndex: nil,
            localTokenCached: tokenCached
        )
    }

    @Test func tokenSummaryIsTranslatedForTheGivenLocale() {
        let summary = GroupPushDebugPresentation.tokenSummary
        let tokens = info(total: 3, active: 2, stale: 1)
        #expect(summary(tokens, Locale(identifier: "en")) == "3 total, 2 active, 1 stale")
        #expect(summary(tokens, Locale(identifier: "de")) == "3 gesamt, 2 aktiv, 1 veraltet")
        #expect(summary(tokens, Locale(identifier: "zh-Hans")) == "共 3 项，2 个有效，1 个陈旧")
        #expect(
            summary(info(total: 5, active: 3, stale: 1), Locale(identifier: "ru"))
                == "всего 5, 3 активных, 1 устаревший"
        )
    }

    @Test func missingRelayHintSummaryPluralizesForTheGivenLocale() {
        let summary = GroupPushDebugPresentation.missingRelayHintSummary
        let english = Locale(identifier: "en")
        #expect(summary(info(missingRelayHints: 1), english) == "1 missing relay hint")
        #expect(summary(info(missingRelayHints: 0), english) == "0 missing relay hints")
        #expect(summary(info(missingRelayHints: 2), english) == "2 missing relay hints")
        let russian = Locale(identifier: "ru")
        #expect(summary(info(missingRelayHints: 21), russian) == "21 отсутствующая подсказка реле")
        #expect(summary(info(missingRelayHints: 3), russian) == "3 отсутствующие подсказки реле")
        #expect(summary(info(missingRelayHints: 5), russian) == "5 отсутствующих подсказок реле")
    }

    @Test func localRegistrationSummaryDescribesEachFlagForTheGivenLocale() {
        let summary = GroupPushDebugPresentation.localRegistrationSummary
        let english = Locale(identifier: "en")
        #expect(
            summary(registration(registered: true, nativePush: true, tokenCached: true), english)
                == "Registered, native push on, token cached"
        )
        #expect(
            summary(registration(registered: false, nativePush: false, tokenCached: false), english)
                == "Not registered, native push off, no local token"
        )
        #expect(
            summary(registration(registered: true, nativePush: false, tokenCached: false), Locale(identifier: "de"))
                == "Registriert, nativer Push aus, kein lokales Token"
        )
        #expect(
            summary(registration(registered: false, nativePush: true, tokenCached: true), Locale(identifier: "zh-Hant"))
                == "未註冊，原生推播已開啟，權杖已快取"
        )
    }

    /// Two app languages with different results, so no single host language
    /// can satisfy both if a default stops following the selected language.
    @Test func summariesFollowTheSelectedAppLanguageByDefault() {
        let presentation = GroupPushDebugPresentation.self
        let tokens = info(total: 3, active: 2, stale: 1, missingRelayHints: 3)
        let localRegistration = registration(registered: true, nativePush: true, tokenCached: false)
        let german = Locale(identifier: "de")
        let russian = Locale(identifier: "ru")
        #expect(
            presentation.tokenSummary(for: tokens, locale: german)
                != presentation.tokenSummary(for: tokens, locale: russian)
        )
        #expect(
            presentation.missingRelayHintSummary(for: tokens, locale: german)
                != presentation.missingRelayHintSummary(for: tokens, locale: russian)
        )
        #expect(
            presentation.localRegistrationSummary(for: localRegistration, locale: german)
                != presentation.localRegistrationSummary(for: localRegistration, locale: russian)
        )
        for (language, locale) in [(AppLanguage.german, german), (.russian, russian)] {
            withAppLanguage(language) {
                #expect(
                    presentation.tokenSummary(for: tokens)
                        == presentation.tokenSummary(for: tokens, locale: locale)
                )
                #expect(
                    presentation.missingRelayHintSummary(for: tokens)
                        == presentation.missingRelayHintSummary(for: tokens, locale: locale)
                )
                #expect(
                    presentation.localRegistrationSummary(for: localRegistration)
                        == presentation.localRegistrationSummary(for: localRegistration, locale: locale)
                )
            }
        }
    }
}

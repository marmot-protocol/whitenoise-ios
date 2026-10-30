import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MaintenanceDiagnosticsPresentationTests {
    @Test func maintenanceLabelsAreTranslatedForTheGivenLocale() {
        let presentation = MaintenanceDiagnosticsPresentation.self
        let english = Locale(identifier: "en")
        #expect(presentation.phaseLabel(.pendingPublication, locale: english) == "Pending publication")
        #expect(presentation.phaseLabel(.retry, locale: english) == "Retrying")
        #expect(presentation.triggerLabel(.postJoin, locale: english) == "Post-join")
        #expect(presentation.evolutionPhaseLabel(.attempting, locale: english) == "Attempting")

        let german = Locale(identifier: "de")
        #expect(presentation.phaseLabel(.eoseTimeout, locale: german) == "EOSE-Zeitüberschreitung")
        #expect(presentation.phaseLabel(.clockSkewBlocked, locale: german) == "Durch Uhrabweichung blockiert")
        #expect(presentation.triggerLabel(.periodic, locale: german) == "Regelmäßig")
        #expect(presentation.evolutionPhaseLabel(.confirmed, locale: german) == "Bestätigt")

        let russian = Locale(identifier: "ru")
        #expect(presentation.phaseLabel(.paused, locale: russian) == "Приостановлено")
        #expect(presentation.triggerLabel(.manual, locale: russian) == "Вручную")
        #expect(presentation.evolutionPhaseLabel(.supersededByConvergence, locale: russian)
            == "Заменено в результате конвергенции")
        #expect(presentation.phaseLabel(.supersededByConvergence, locale: Locale(identifier: "zh-Hant"))
            == "已被收斂取代")
    }

    /// Every case resolves to its own catalog entry: a label that falls back
    /// to its English key, or two cases sharing one by mistake, shows up here.
    @Test func everyMaintenanceLabelHasADistinctTranslation() {
        let presentation = MaintenanceDiagnosticsPresentation.self
        let phases: [MaintenancePhaseFfi] = [
            .catchUp, .eoseTimeout, .grace, .quiet, .jitter, .overdue, .paused, .clockSkewBlocked,
            .pendingPublication, .fanout, .retry, .supersededByConvergence, .complete, .failed
        ]
        let triggers: [MaintenanceTriggerFfi] = [.postJoin, .periodic, .manual]
        let evolutionPhases: [GroupEvolutionPhaseFfi] = [.preparing, .prepared, .attempting, .confirmed]
        for locale in ["de", "ru", "zh-Hans"].map(Locale.init(identifier:)) {
            let english = Locale(identifier: "en")
            let labels = phases.map { (presentation.phaseLabel($0, locale: english), presentation.phaseLabel($0, locale: locale)) }
                + triggers.map { (presentation.triggerLabel($0, locale: english), presentation.triggerLabel($0, locale: locale)) }
                + evolutionPhases.map {
                    (presentation.evolutionPhaseLabel($0, locale: english), presentation.evolutionPhaseLabel($0, locale: locale))
                }
            for (source, translated) in labels {
                #expect(translated != source, "\(source) is untranslated in \(locale.identifier)")
            }
            #expect(Set(labels.map(\.1)).count == labels.count)
        }
    }

    @Test func obligationSummaryIsTranslatedForTheGivenLocale() {
        let summary = MaintenanceDiagnosticsPresentation.obligationSummary
        #expect(summary(3, 1, Locale(identifier: "en")) == "3 total, 1 overdue")
        #expect(summary(3, 1, Locale(identifier: "de")) == "3 gesamt, 1 überfällig")
        #expect(summary(3, 1, Locale(identifier: "zh-Hans")) == "共 3 项，1 项逾期")
        #expect(summary(5, 2, Locale(identifier: "ru")) == "всего 5, просрочено 2")
    }

    @Test func fanoutSummaryPluralizesEachCountForTheGivenLocale() {
        let summary = MaintenanceDiagnosticsPresentation.fanoutSummary
        let english = Locale(identifier: "en")
        #expect(summary(1, 1, english) == "1 record, 1 failed target")
        #expect(summary(2, 0, english) == "2 records, 0 failed targets")
        let russian = Locale(identifier: "ru")
        #expect(summary(3, 5, russian) == "3 записи, 5 целей с ошибкой")
        #expect(summary(21, 1, russian) == "21 запись, 1 цель с ошибкой")
        #expect(summary(2, 1, Locale(identifier: "zh-Hant")) == "2 筆記錄，1 個目標失敗")
    }

    /// Two app languages with different results, so no single host language
    /// can satisfy both if a default stops following the selected language.
    @Test func summariesAndLabelsFollowTheSelectedAppLanguageByDefault() {
        let presentation = MaintenanceDiagnosticsPresentation.self
        let german = Locale(identifier: "de")
        let russian = Locale(identifier: "ru")
        #expect(
            presentation.obligationSummary(total: 3, overdue: 1, locale: german)
                != presentation.obligationSummary(total: 3, overdue: 1, locale: russian)
        )
        #expect(
            presentation.fanoutSummary(records: 3, failedTargets: 5, locale: german)
                != presentation.fanoutSummary(records: 3, failedTargets: 5, locale: russian)
        )
        #expect(presentation.phaseLabel(.grace, locale: german) != presentation.phaseLabel(.grace, locale: russian))
        #expect(
            presentation.triggerLabel(.postJoin, locale: german)
                != presentation.triggerLabel(.postJoin, locale: russian)
        )
        #expect(
            presentation.evolutionPhaseLabel(.prepared, locale: german)
                != presentation.evolutionPhaseLabel(.prepared, locale: russian)
        )
        for (language, locale) in [(AppLanguage.german, german), (.russian, russian)] {
            withAppLanguage(language) {
                #expect(
                    presentation.obligationSummary(total: 3, overdue: 1)
                        == presentation.obligationSummary(total: 3, overdue: 1, locale: locale)
                )
                #expect(
                    presentation.fanoutSummary(records: 3, failedTargets: 5)
                        == presentation.fanoutSummary(records: 3, failedTargets: 5, locale: locale)
                )
                #expect(presentation.phaseLabel(.grace) == presentation.phaseLabel(.grace, locale: locale))
                #expect(presentation.triggerLabel(.postJoin) == presentation.triggerLabel(.postJoin, locale: locale))
                #expect(
                    presentation.evolutionPhaseLabel(.prepared)
                        == presentation.evolutionPhaseLabel(.prepared, locale: locale)
                )
            }
        }
    }

    @Test func peerControlledFailureCodeIsBoundedAndSanitized() throws {
        let code = try #require(MaintenanceDiagnosticsPresentation.failureCode(
            "  retry\u{202E}\nfailed  " + String(repeating: "x", count: 200)
        ))

        #expect(!code.contains("\u{202E}"))
        #expect(!code.contains("\n"))
        #expect(code.count <= 120)
    }

    @Test func hostileTimestampClampsWithoutTrapping() {
        #expect(MaintenanceDiagnosticsPresentation.date(UInt64.max) == .distantFuture)
        #expect(MaintenanceDiagnosticsPresentation.date(nil) == nil)
    }

    @Test func relayHealthIncludesConnectionAndForwarderFailures() {
        let lines = DiagnosticsView.relayHealthText(RelayHealthFfi(
            sdkBacked: true,
            totalRelays: 4,
            initialized: 4,
            pending: 0,
            connecting: 1,
            connected: 2,
            disconnected: 1,
            terminated: 0,
            banned: 0,
            sleeping: 0,
            connectionAttempts: 8,
            connectionSuccesses: 6,
            notificationForwarderRunning: false,
            notificationForwarderRestarts: 2,
            notificationForwarderLagIncidents: 3,
            notificationForwarderLaggedNotifications: 9,
            notificationForwarderPanics: 1,
            notificationForwarderUnexpectedExits: 1
        ))

        #expect(lines.count == 3)
        #expect(lines[0].contains("2/4 connected"))
        #expect(lines[1].contains("6/8 succeeded"))
        #expect(lines[2].contains("stopped"))
        #expect(lines[2].contains("1 panics"))
    }
}

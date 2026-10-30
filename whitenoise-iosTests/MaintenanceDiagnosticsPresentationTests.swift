import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MaintenanceDiagnosticsPresentationTests {
    @Test func maintenancePhasesHaveStableDeveloperLabels() {
        #expect(MaintenanceDiagnosticsPresentation.phaseLabel(.pendingPublication) == "Pending publication")
        #expect(MaintenanceDiagnosticsPresentation.phaseLabel(.clockSkewBlocked) == "Clock skew blocked")
        #expect(MaintenanceDiagnosticsPresentation.evolutionPhaseLabel(.attempting) == "Attempting")
        #expect(MaintenanceDiagnosticsPresentation.triggerLabel(.postJoin) == "Post-join")
    }

    @Test func obligationSummaryIsTranslatedForTheGivenLocale() {
        let summary = MaintenanceDiagnosticsPresentation.obligationSummary
        #expect(summary(3, 1, Locale(identifier: "en")) == "3 total, 1 overdue")
        #expect(summary(3, 1, Locale(identifier: "de")) == "3 gesamt, 1 überfällig")
        #expect(summary(3, 1, Locale(identifier: "zh-Hans")) == "共 3 项，1 项逾期")
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

    @Test func summariesFollowTheSelectedAppLanguageByDefault() {
        let presentation = MaintenanceDiagnosticsPresentation.self
        withAppLanguage(.german) {
            #expect(
                presentation.obligationSummary(total: 3, overdue: 1)
                    == presentation.obligationSummary(total: 3, overdue: 1, locale: Locale(identifier: "de"))
            )
        }
        withAppLanguage(.russian) {
            #expect(
                presentation.fanoutSummary(records: 3, failedTargets: 5)
                    == presentation.fanoutSummary(records: 3, failedTargets: 5, locale: Locale(identifier: "ru"))
            )
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

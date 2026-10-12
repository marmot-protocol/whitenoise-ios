import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct StartupDiagnosticsTests {
    @Test func preferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "startup-diagnostics-\(UUID())"))
        #expect(!StartupDiagnosticsPreference.isEnabled(defaults))
        StartupDiagnosticsPreference.setEnabled(true, defaults)
        #expect(StartupDiagnosticsPreference.isEnabled(defaults))
        StartupDiagnosticsPreference.setEnabled(false, defaults)
        #expect(!StartupDiagnosticsPreference.isEnabled(defaults))
    }

    @Test func rowsAndExportCarryOnlyPhasesDurationsAndMigrations() {
        let migration = NativeStartupObservationFfi(
            token: 3, stage: .migrationApply, elapsedMs: 1_250, stageElapsedMs: 900,
            migrationVersion: 107, migrationsCompleted: 6, outcome: .success
        )
        let open = NativeStartupObservationFfi(
            token: 3, stage: .encryptedStoreOpen, elapsedMs: 40, stageElapsedMs: 40,
            migrationVersion: nil, migrationsCompleted: 0, outcome: .active
        )
        let rows = StartupDiagnosticsPresentation.rows([migration, open])
        #expect(rows.map(\.stage) == ["migrationApply", "encryptedStoreOpen"])
        #expect(rows[0].detail == "900 ms · total 1250 ms · success · migration 107 · 6 migrations done")
        #expect(rows[1].detail == "40 ms · total 40 ms · active")
        #expect(Set(rows.map(\.id)).count == 2)

        let snapshot = NativeStartupSnapshotFfi(
            enabled: true, active: [open], events: [migration], droppedEvents: 2, droppedScopes: 0
        )
        let text = StartupDiagnosticsPresentation.exportText(snapshot)
        #expect(text.contains("dropped events: 2"))
        #expect(text.contains("#3 migrationApply 900 ms"))
        #expect(text.contains("#3 encryptedStoreOpen 40 ms"))
    }
}

struct GroupEventPresentationPolicyTests {
    @Test func onlyDeviceLocalMembershipEventsRefreshTheOpenConversation() {
        #expect(GroupEventPresentationPolicy.refreshesMembershipPresentation(.localGroupCopyTerminated(voluntary: true)))
        #expect(GroupEventPresentationPolicy.refreshesMembershipPresentation(.localGroupCopyTerminated(voluntary: false)))
        #expect(GroupEventPresentationPolicy.refreshesMembershipPresentation(.localGroupCopyRestored))
        #expect(GroupEventPresentationPolicy.refreshesMembershipPresentation(.groupMemberLeavesRemoved(epoch: 4)))
        #expect(!GroupEventPresentationPolicy.refreshesMembershipPresentation(.messageReceived(senderIdHex: "", epoch: 1)))
        #expect(!GroupEventPresentationPolicy.refreshesMembershipPresentation(.epochChanged(from: 1, to: 2)))
    }
}

import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@Suite(.serialized)
struct HostStageTimingTests {
    private final class Captured: Sendable {
        let samples = Mutex<[(HostPerformanceOperationFfi, UInt64, HostPerformanceOutcomeFfi)]>([])
    }

    @Test func recordStageReportsTheSharedOperationWithElapsedTimeAndOutcome() async {
        let recorder = ProductAnalyticsRecorder()
        let captured = Captured()
        recorder.activateSink(
            performance: { operation, milliseconds, outcome in
                captured.samples.withLock { $0.append((operation, milliseconds, outcome)) }
            },
            timing: { _, _, _ in }
        ) { _ in }
        let start = ContinuousClock.now
        let timing = recorder.beginTiming(at: start)

        await recorder.recordStage(.timelineOpen, since: timing, outcome: .unavailable,
                                   at: start.advanced(by: .milliseconds(1_250)))?.value

        let samples = captured.samples.withLock { $0 }
        #expect(samples.count == 1)
        #expect(samples.first?.0 == .timelineOpen)
        #expect(samples.first?.1 == 1_250)
        #expect(samples.first?.2 == .unavailable)
    }

    @Test func stagesAreNotTimedWithoutConsent() {
        let recorder = ProductAnalyticsRecorder()
        let timing = recorder.beginTiming()
        #expect(timing == nil)
        #expect(recorder.recordStage(.messageSend, since: timing) == nil)
    }

    @Test func elapsedMillisecondsClampsNegativeSpansAndSaturatesOverflow() {
        let start = ContinuousClock.now
        #expect(ProductAnalyticsRecorder.elapsedMilliseconds(from: start, to: start.advanced(by: .milliseconds(-5))) == 0)
        #expect(ProductAnalyticsRecorder.elapsedMilliseconds(from: start, to: start.advanced(by: .microseconds(2_999))) == 2)
        #expect(ProductAnalyticsRecorder.elapsedMilliseconds(from: start, to: start.advanced(by: .seconds(Int64.max))) == .max)
    }

    @Test func settingsSaveTimingReportsOnlyWhenAHandlerIsInstalled() {
        let reports = Mutex(0)
        #expect(HostSettingsSaveTiming.measure { 7 } == 7)

        HostSettingsSaveTiming.install { _ in reports.withLock { $0 += 1 } }
        defer { HostSettingsSaveTiming.install(nil) }
        let defaults = UserDefaults(suiteName: "HostStageTimingTests-\(UUID().uuidString)")!
        NotificationPreviewStore.setMode(.senderOnly, defaults: defaults)
        AppLanguage.setCurrentRawValue(AppLanguage.system.rawValue, defaults: defaults,
                                       notificationCenter: NotificationCenter())

        #expect(reports.withLock { $0 } == 2)
        #expect(NotificationPreviewStore.mode(defaults: defaults) == .senderOnly)
    }
}

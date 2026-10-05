import Foundation
import MarmotKit
import Synchronization
import Testing
@testable import whitenoise_ios

@Suite(.serialized)
struct HostStageTimingTests {
    @TaskLocal private static var capturesSettingsSaves = false

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

    @Test func settingsSaveTimingReportsOnlyWhenAHandlerIsInstalled() async {
        let reports = Mutex(0)
        HostSettingsSaveTiming.install(nil)
        #expect(HostSettingsSaveTiming.measure { 7 } == 7)

        HostSettingsSaveTiming.install { _ in
            guard Self.capturesSettingsSaves else { return }
            reports.withLock { $0 += 1 }
        }
        defer { HostSettingsSaveTiming.install(nil) }
        let suiteName = "HostStageTimingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An unrelated writer must not enter this test's report count.
        let unrelatedResult = await Task.detached {
            HostSettingsSaveTiming.measure { 11 }
        }.value
        #expect(unrelatedResult == 11)

        Self.$capturesSettingsSaves.withValue(true) {
            NotificationPreviewStore.setMode(.senderOnly, defaults: defaults)
            AppLanguage.setCurrentRawValue(AppLanguage.system.rawValue, defaults: defaults,
                                           notificationCenter: NotificationCenter())
            #expect(reports.withLock { $0 } == 2)

            HostSettingsSaveTiming.install(nil)
            #expect(HostSettingsSaveTiming.measure { 13 } == 13)
        }

        #expect(reports.withLock { $0 } == 2)
        #expect(NotificationPreviewStore.mode(defaults: defaults) == .senderOnly)
    }
}

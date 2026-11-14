import Foundation

/// Where `TimelineStore` reports how long its timeline work took.
struct TimelineStoreTimings {
    var begin: @MainActor () -> ProductAnalyticsRecorder.Timing?
    var record: @MainActor (ProductTimingStage, ProductAnalyticsRecorder.Timing?) -> Void

    /// The app's product analytics recorder, read through the store's weak
    /// app state on every call.
    static func analytics(of appState: AppState?) -> TimelineStoreTimings {
        TimelineStoreTimings(
            begin: { [weak appState] in appState?.productAnalytics.beginTiming() },
            record: { [weak appState] stage, timing in
                appState?.productAnalytics.recordTiming(stage, since: timing)
            }
        )
    }
}

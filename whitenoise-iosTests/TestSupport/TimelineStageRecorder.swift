@testable import whitenoise_ios

/// Records the timing stages a timeline store reports, so a test can count
/// how often the store did a piece of work.
@MainActor
final class TimelineStageRecorder {
    private(set) var stages: [ProductTimingStage] = []

    var timings: TimelineStoreTimings {
        TimelineStoreTimings(
            begin: { nil },
            record: { [weak self] stage, _ in self?.stages.append(stage) }
        )
    }

    func count(_ stage: ProductTimingStage) -> Int {
        stages.filter { $0 == stage }.count
    }
}

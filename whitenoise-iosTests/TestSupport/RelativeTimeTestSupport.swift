import Foundation
@testable import whitenoise_ios

/// Builds the real formatters and counts them, so a test can tell when the
/// `RelativeTime` cache built a formatter and when it reused one.
@MainActor
final class RelativeTimeFormatterBuildCounter {
    private(set) var dateFormatterBuilds = 0
    private(set) var durationFormatterBuilds = 0
    /// Every date formatter built, in order; the cache configures each one
    /// (locale, template) after the factory returns it.
    private(set) var builtDateFormatters: [DateFormatter] = []

    lazy var formatters = RelativeTimeFormatters(
        makeDateFormatter: { [unowned self] in
            self.dateFormatterBuilds += 1
            let formatter = DateFormatter()
            self.builtDateFormatters.append(formatter)
            return formatter
        },
        makeDurationFormatter: { [unowned self] in
            self.durationFormatterBuilds += 1
            return DateComponentsFormatter()
        }
    )
}

import Foundation
import Synchronization

/// Times host preference writes for MDK's `host_settings_save` stage. The app
/// installs a handler; the notification extension never does, so its writes
/// skip the clock entirely.
nonisolated enum HostSettingsSaveTiming {
    private static let handler = Mutex<(@Sendable (UInt64) -> Void)?>(nil)

    static func install(_ newHandler: (@Sendable (UInt64) -> Void)?) {
        handler.withLock { $0 = newHandler }
    }

    static func measure<T>(_ write: () throws -> T) rethrows -> T {
        guard let report = handler.withLock({ $0 }) else { return try write() }
        let startedAt = ContinuousClock.now
        let result = try write()
        let elapsed = startedAt.duration(to: .now).components
        let milliseconds = UInt64(max(0, elapsed.seconds)) * 1_000
            + UInt64(max(0, elapsed.attoseconds)) / 1_000_000_000_000_000
        report(milliseconds)
        return result
    }
}

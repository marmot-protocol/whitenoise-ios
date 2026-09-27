import Foundation

struct ChatTitleFallbackGrace {
    static let duration: Duration = .seconds(3)

    private var firstSeenByGroupId: [String: ContinuousClock.Instant] = [:]

    mutating func isPending(
        groupIdHex: String,
        isFallback: Bool,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard isFallback else {
            firstSeenByGroupId[groupIdHex] = nil
            return false
        }
        let firstSeen = firstSeenByGroupId[groupIdHex] ?? now
        firstSeenByGroupId[groupIdHex] = firstSeen
        return now < firstSeen + Self.duration
    }

    func nextDeadline(after now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        firstSeenByGroupId.values
            .map { $0 + Self.duration }
            .filter { $0 > now }
            .min()
    }

    mutating func reset() {
        firstSeenByGroupId = [:]
    }
}

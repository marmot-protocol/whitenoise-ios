nonisolated enum DonationMonthlyStatus: Equatable, Sendable {
    case active
    case cancellationScheduled
    case overdue
    case incomplete
    case canceled
    case unsupported
}

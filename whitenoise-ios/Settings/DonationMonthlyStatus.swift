/// Presentation states; the payment service is not yet connected to this model.
nonisolated enum DonationMonthlyStatus: Equatable, Sendable {
    case active
    case cancellationScheduled
    case overdue
}

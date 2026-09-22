#if DEBUG
// TEMPORARY — remove this file, its tests, and the marked hooks in SettingsView
// and DonateView after donation UI review. All fixtures and controls are debug-only.
import SwiftUI

nonisolated enum DonationReviewScenario: String, CaseIterable, Identifiable, Sendable {
    case live = "Current app — real payments"
    case newDonor = "New donor — interactive form"
    case monthlyActive = "Monthly active + payment history"
    case cancellationScheduled = "Monthly cancellation scheduled"
    case overdue = "Monthly overdue"
    case oneTimeSuccess = "One-time donation — success sheet"
    case monthlySuccess = "Monthly donation — success sheet"
    case paymentFailed = "Payment failed"
    case loading = "Loading Apple Pay"
    case setupRequired = "Set Up Apple Pay"
    case unavailable = "Apple Pay unavailable on device"

    var id: Self { self }

    enum Group: String, CaseIterable, Sendable {
        case current = "Current app"
        case donors = "Donors and monthly status"
        case success = "Success sheets"
        case payment = "Payment and Apple Pay"
    }

    struct GroupOptions: Identifiable, Sendable {
        let id: Group
        let scenarios: [DonationReviewScenario]
    }

    static let groups = Group.allCases.map { group in
        GroupOptions(id: group, scenarios: allCases.filter { $0.group == group })
    }

    var group: Group {
        switch self {
        case .live: .current
        case .newDonor, .monthlyActive, .cancellationScheduled, .overdue: .donors
        case .oneTimeSuccess, .monthlySuccess: .success
        case .paymentFailed, .loading, .setupRequired, .unavailable: .payment
        }
    }

    @MainActor
    func makeFixture(now: Date = .now) -> DonationReviewFixture {
        guard self != .live else {
            return DonationReviewFixture(model: DonateViewModel(), support: DonationSupportSummary())
        }

        let model = DonateViewModel(
            client: DonationReviewClient(),
            coordinator: DonationReviewCoordinator(scenario: self),
            managementURL: DonationReviewFixture.managementURL,
            isApplePayPrepared: self != .loading
        )
        let status: DonationMonthlyStatus?
        switch self {
        case .monthlyActive, .monthlySuccess: status = .active
        case .cancellationScheduled: status = .cancellationScheduled
        case .overdue: status = .overdue
        default: status = nil
        }
        if status != nil { model.cadence = .monthly }
        let monthly = status.map {
            MonthlyDonationSummary(
                status: $0,
                amountCents: 2_500,
                nextPaymentDate: $0 == .active ? Calendar.current.date(byAdding: .month, value: 1, to: now) : nil,
                cancellationDate: $0 == .cancellationScheduled ? Calendar.current.date(byAdding: .month, value: 1, to: now) : nil
            )
        }
        // Invoice variants are reached through Payments, not separate scenarios.
        let amounts = status == nil ? [] : [2_500, 1_000, 5_000, 10_000, 2_500]
        let history = amounts.enumerated().map { index, amount in
            let receipt: DonationReceiptResponse?
            switch index {
            case 1: receipt = DonationReceiptResponse(status: .pending, url: nil)
            case 2: receipt = DonationReceiptResponse(status: .failed, url: nil)
            case 3: receipt = nil
            default: receipt = DonationReceiptResponse(status: .available, url: DonationReviewFixture.receiptURL)
            }
            return DonationPayment(
                id: "review-\(index)",
                amountCents: amount,
                date: now.addingTimeInterval(TimeInterval(-index * 30 * 86_400)),
                cadence: index.isMultiple(of: 2) ? .monthly : .oneTime,
                invoice: index == 3 ? .receiptToken("review-checking") : .receiptToken("review-\(index)"),
                receipt: receipt
            )
        }
        return DonationReviewFixture(
            model: model,
            support: DonationSupportSummary(monthly: monthly, payments: history)
        )
    }
}

@MainActor
struct DonationReviewFixture {
    nonisolated static let managementURL = URL(string: "https://donation-review.invalid/manage")!
    nonisolated static let receiptURL = URL(string: "https://donation-review.invalid/receipt")!
    let model: DonateViewModel
    let support: DonationSupportSummary
}

@MainActor
@Observable
final class DonationReviewSession {
    private(set) var scenario: DonationReviewScenario
    private(set) var fixture: DonationReviewFixture
    private(set) var revision = UUID()
    private var activated = false

    init(scenario: DonationReviewScenario = .live) {
        self.scenario = scenario
        fixture = scenario.makeFixture()
    }

    func select(_ scenario: DonationReviewScenario) {
        fixture.model.cancel()
        self.scenario = scenario
        fixture = scenario.makeFixture()
        activated = false
        revision = UUID()
    }

    func activate() {
        guard !activated else { return }
        activated = true
        switch scenario {
        case .oneTimeSuccess, .monthlySuccess, .paymentFailed:
            fixture.model.startDonation()
        default: break
        }
    }
}

nonisolated private struct DonationReviewSessionKey: EnvironmentKey {
    static let defaultValue: DonationReviewSession? = nil
}

extension EnvironmentValues {
    var donationReviewSession: DonationReviewSession? {
        get { self[DonationReviewSessionKey.self] }
        set { self[DonationReviewSessionKey.self] = newValue }
    }
}

struct DonationReviewHost: View {
    @State private var session: DonationReviewSession
    @State private var testLink: TestLink?

    init(scenario: DonationReviewScenario = .live) {
        _session = State(initialValue: DonationReviewSession(scenario: scenario))
    }

    var body: some View {
        DonateView(model: session.fixture.model, support: session.fixture.support)
            .id(session.revision)
            .environment(\.donationReviewSession, session)
            .environment(\.openURL, OpenURLAction { url in
                guard session.scenario != .live else { return .systemAction }
                testLink = url.path == "/manage" ? .management : .receipt
                return .handled
            })
            .task(id: session.revision) { session.activate() }
            .sheet(item: $testLink) { link in
                NavigationStack {
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: link.rawValue)
                        } icon: {
                            Image(systemName: "testtube.2")
                        }
                    } description: {
                        Text(verbatim: "This is a local test destination. No payment service or external page was opened.")
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { testLink = nil } label: { Text(verbatim: "Close") }
                        }
                    }
                }
            }
    }

    private enum TestLink: String, Identifiable {
        case management = "Monthly donation management"
        case receipt = "Donation receipt"
        var id: Self { self }
    }
}

struct DonationReviewControls: View {
    let session: DonationReviewSession
    @State private var showingScenarios = false

    var body: some View {
        Section {
            // Keep the selector inline: Donate is already inside the Settings sheet.
            DisclosureGroup(isExpanded: $showingScenarios) {
                ForEach(DonationReviewScenario.groups) { group in
                    Text(verbatim: group.id.rawValue)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.scenarios) { scenario in
                        Button {
                            session.select(scenario)
                        } label: {
                            HStack {
                                Text(verbatim: scenario.rawValue)
                                Spacer()
                                if scenario == session.scenario {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityAddTraits(scenario == session.scenario ? .isSelected : [])
                    }
                }
            } label: {
                Label {
                    Text(verbatim: "Testing: choose scenario")
                } icon: {
                    Image(systemName: "testtube.2")
                }
            }
            Text(verbatim: session.scenario.rawValue)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "Temporary donation testing")
        } footer: {
            Text(verbatim: session.scenario == .live
                 ? "Current app behavior. Payment buttons and links are real. Choose a scenario to use fake data."
                 : "Sample data only. Switch tabs, edit amounts, and tap Donate to test either success sheet. In payment history, the first four invoices show available, pending, unavailable, and loading states. Wallet setup and links are simulated. Reselect a scenario to reset it.")
        }
    }
}

private actor DonationReviewClient: DonationClient {
    func configuration() async throws -> DonationRuntimeConfig { throw CancellationError() }
    func createDonation(_ request: DonationCreateRequest) async throws -> DonationCreateResponse {
        throw CancellationError()
    }
    func receipt(for token: String) async throws -> DonationReceiptResponse {
        if token == "review-checking" {
            let pending = AsyncStream<Void>(bufferingPolicy: .unbounded) { _ in }
            for await _ in pending {}
            throw CancellationError()
        }
        return DonationReceiptResponse(status: .available, url: DonationReviewFixture.receiptURL)
    }
}

@MainActor
@Observable
private final class DonationReviewCoordinator: DonationPaymentCoordinating {
    let scenario: DonationReviewScenario
    private var availabilityValue: DonationApplePayAvailability

    init(scenario: DonationReviewScenario) {
        self.scenario = scenario
        switch scenario {
        case .setupRequired: availabilityValue = .setupRequired
        case .unavailable: availabilityValue = .unavailable
        default: availabilityValue = .ready
        }
    }

    func prepare() async throws {
        if scenario == .loading {
            // Keep this review state visible until SwiftUI cancels the screen task.
            let pending = AsyncStream<Void>(bufferingPolicy: .unbounded) { _ in }
            for await _ in pending {}
            throw CancellationError()
        }
    }

    func availability(for draft: DonationDraft) -> DonationApplePayAvailability { availabilityValue }

    func donate(_ draft: DonationDraft) async throws -> DonationPaymentSuccess {
        switch scenario {
        case .paymentFailed: throw DonationPaymentCoordinatorError.paymentFailed
        default: return DonationPaymentSuccess(receiptToken: "local-review-receipt")
        }
    }

    func openPaymentSetup() { availabilityValue = .ready }
    func cancel() {}
}

#Preview("Donate — monthly supporter and history") {
    NavigationStack { DonationReviewHost(scenario: .monthlyActive) }
        .wnNeutralAccentTint()
}

#Preview("Donate — new donor") {
    NavigationStack { DonationReviewHost(scenario: .newDonor) }
        .wnNeutralAccentTint()
}
// TEMPORARY — sample document, never a real invoice.
struct DonationReviewInvoice: View {
    let payment: DonationPayment

    static func sampleText(_ payment: DonationPayment) -> String {
        "SAMPLE — NOT A REAL INVOICE\nInternet Privacy Foundation\n\(DonatePresentation.formattedAmount(cents: payment.amountCents))\n\(payment.cadence == .monthly ? "Monthly" : "One time")\n\(payment.date.formatted(date: .long, time: .omitted))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: "SAMPLE — NOT A REAL INVOICE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: "Internet Privacy Foundation")
                    .font(.title2.bold())
                DonationHistoryRow(donation: payment)
                Divider()
                Text(verbatim: "Paid with Apple Pay")
                Text(verbatim: "Thank you for supporting private communication.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
#endif

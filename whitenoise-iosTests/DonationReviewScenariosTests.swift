#if DEBUG
// TEMPORARY — remove with DonationReviewScenarios.swift after donation UI review.
import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct DonationReviewScenariosTests {
    @Test func supporterHistoryIncludesBothCadencesAndDistinctInvoiceStates() async throws {
        let fixture = DonationReviewScenario.monthlyActive.makeFixture()
        let payments = fixture.support.payments

        #expect(fixture.model.cadence == .monthly)
        #expect(fixture.support.monthly?.status == .active)
        #expect(payments.count == 5)
        #expect(payments.contains { $0.cadence == .monthly })
        #expect(payments.contains { $0.cadence == .oneTime })
        #expect(fixture.support.recentPayments.count == 3)
        #expect(fixture.model.managementURL?.host == "donation-review.invalid")
        #expect(payments[0].receipt?.status == .available)
        #expect(payments[1].receipt?.status == .pending)
        #expect(payments[2].receipt?.status == .failed)
        #expect(payments[3].receipt == nil)
        #expect(payments[3].invoice == .receiptToken("review-checking"))

        for payment in payments[1...2] {
            guard case let .receiptToken(token) = payment.invoice else {
                Issue.record("Missing retryable invoice token")
                continue
            }
            let response = try await fixture.model.receipt(for: token)
            #expect(response.status == .available)
            #expect(response.url?.host == "donation-review.invalid")
        }
    }

    @Test(arguments: [DonationCadence.oneTime, .monthly])
    func successAndHistoryAreReachableFromTheInteractiveForm(_ cadence: DonationCadence) async {
        let fixture = DonationReviewScenario.newDonor.makeFixture()
        let model = fixture.model
        #expect(fixture.support.payments.isEmpty)
        #expect(fixture.support.monthly == nil)
        model.cadence = cadence
        model.updateCustomAmount("42")
        model.startDonation()
        await waitUntil { !model.isProcessing }

        #expect(model.paymentSucceeded)
        #expect(model.completedPayments.first?.cadence == cadence)
        #expect(model.completedPayments.first?.amountCents == 4_200)
        #expect(model.completedPayments.first?.receipt == nil)
    }

    @Test(arguments: [DonationReviewScenario.oneTimeSuccess, .monthlySuccess])
    func directSuccessScenariosActivateOnceAndCanBeReplayed(_ scenario: DonationReviewScenario) async {
        let session = DonationReviewSession(scenario: scenario)
        let model = session.fixture.model
        let cadence: DonationCadence = scenario == .monthlySuccess ? .monthly : .oneTime
        session.activate()
        await waitUntil { !model.isProcessing }
        #expect(model.paymentSucceeded)
        #expect(model.cadence == cadence)
        #expect(model.completedPayments.count == 1)
        #expect(model.completedPayments.first?.cadence == cadence)

        session.activate()
        #expect(!model.isProcessing)
        #expect(model.completedPayments.count == 1)

        session.select(scenario)
        session.activate()
        let replay = session.fixture.model
        await waitUntil { !replay.isProcessing }
        #expect(replay !== model)
        #expect(replay.paymentSucceeded)
        #expect(replay.completedPayments.count == 1)
    }

    @Test func monthlyFixturesKeepTheirDistinctStatuses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DonationReviewScenario.cancellationScheduled.makeFixture(now: now).support.monthly?.status == .cancellationScheduled)
        #expect(DonationReviewScenario.overdue.makeFixture(now: now).support.monthly?.status == .overdue)
    }

    @Test func failureScenarioShowsAnErrorWithoutRecordingPayment() async {
        let session = DonationReviewSession(scenario: .paymentFailed)
        session.activate()
        let model = session.fixture.model
        await waitUntil { !model.isProcessing }
        #expect(model.errorMessage != nil)
        #expect(!model.paymentSucceeded)
        #expect(model.completedPayments.isEmpty)
    }

    @Test func setupSimulationEnablesApplePayWithoutOpeningWallet() {
        let model = DonationReviewScenario.setupRequired.makeFixture().model
        #expect(model.availability == .setupRequired)
        model.openPaymentSetup()
        #expect(model.availability == .ready)
    }

    @Test func selectingAnotherScenarioCancelsAndReplacesTheOldModel() {
        let session = DonationReviewSession(scenario: .newDonor)
        let previousModel = session.fixture.model
        let previousRevision = session.revision
        previousModel.startDonation()
        #expect(previousModel.isProcessing)

        session.select(.monthlyActive)
        #expect(!previousModel.isProcessing)
        #expect(session.fixture.model !== previousModel)
        #expect(session.revision != previousRevision)
        #expect(!session.fixture.model.isProcessing)
        #expect(session.fixture.model.canDonate)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
        #expect(condition(), sourceLocation: sourceLocation)
    }
}
#endif

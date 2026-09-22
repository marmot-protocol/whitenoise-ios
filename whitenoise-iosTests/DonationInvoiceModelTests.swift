import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct DonationInvoiceModelTests {
    private let url = URL(string: "https://payments.example/receipt")!

    @Test func freshInvoiceStartsLoadingAndPendingInvoiceCanBeRetried() async {
        let model = DonationInvoiceModel(payment: payment())
        #expect(model.state == .loading)
        await model.load { _ in DonationReceiptResponse(status: .pending, url: nil) }
        #expect(model.state == .pending)
        model.retry()
        #expect(model.state == .loading)
        await model.load { _ in DonationReceiptResponse(status: .available, url: url) }
        #expect(model.state == .available(url))
    }

    @Test func failureCanBeRetriedButMissingSourceCannot() async {
        let model = DonationInvoiceModel(payment: payment())
        await model.load { _ in throw DonationClientError.serviceUnavailable }
        #expect(model.state == .unavailable)
        #expect(model.canRetry)
        model.retry()
        await model.load { _ in DonationReceiptResponse(status: .available, url: url) }
        #expect(model.state == .available(url))

        let unavailable = DonationInvoiceModel(payment: DonationPayment(id: "missing", amountCents: 100, date: .now))
        #expect(unavailable.state == .unavailable)
        #expect(!unavailable.canRetry)
    }

    @Test func cachedAndDirectInvoicesDoNotStartAnotherLookup() async {
        var cached = payment()
        cached.receipt = DonationReceiptResponse(status: .available, url: url)
        for payment in [cached, DonationPayment(id: "direct", amountCents: 100, date: .now, invoice: .url(url))] {
            let model = DonationInvoiceModel(payment: payment)
            #expect(model.state == .available(url))
            await model.load { _ in
                Issue.record("An already loaded invoice must not be fetched again")
                throw DonationClientError.serviceUnavailable
            }
        }
    }

    @Test func staleLookupCannotReplaceARetriedInvoice() async {
        let model = DonationInvoiceModel(payment: payment())
        var continuation: CheckedContinuation<DonationReceiptResponse, Error>?
        let oldLookup = Task {
            await model.load { _ in
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        for _ in 0..<200 where continuation == nil { await Task.yield() }
        guard let continuation else {
            oldLookup.cancel()
            Issue.record("Lookup did not start")
            return
        }
        model.retry()
        await model.load { _ in DonationReceiptResponse(status: .available, url: url) }
        continuation.resume(throwing: DonationClientError.serviceUnavailable)
        await oldLookup.value
        #expect(model.state == .available(url))
    }

    @Test func cancellationDoesNotBecomeInvoiceFailure() async {
        let model = DonationInvoiceModel(payment: payment())
        await model.load { _ in throw CancellationError() }
        #expect(model.state == .loading)
    }

    private func payment() -> DonationPayment {
        DonationPayment(id: "payment", amountCents: 2_500, date: .now, invoice: .receiptToken("token"))
    }
}

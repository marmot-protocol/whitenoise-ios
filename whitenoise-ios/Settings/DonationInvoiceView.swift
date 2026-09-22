import SwiftUI
import WebKit

struct DonationInvoiceView: View {
    @Environment(\.dismiss) private var dismiss
    let payment: DonationPayment
    let loadReceipt: (String) async throws -> DonationReceiptResponse
    @State private var model: DonationInvoiceModel
    @State private var requestID = UUID()
    @State private var webLoading = true
    @State private var webFailed = false

    init(payment: DonationPayment, loadReceipt: @escaping (String) async throws -> DonationReceiptResponse) {
        self.payment = payment
        self.loadReceipt = loadReceipt
        _model = State(initialValue: DonationInvoiceModel(payment: payment))
    }

    private var invoiceURL: URL? {
        model.state.url
    }

    var body: some View {
        NavigationStack {
            invoiceContent
                .localizedNavigationTitle("Invoice")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        WNIconButton(title: "Close", systemImage: "xmark", chrome: .container) { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        #if DEBUG
                        if isSample {
                            ShareLink(item: DonationReviewInvoice.sampleText(payment)) {
                                Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                            }
                            .wnIconButtonChrome(chrome: .container)
                        } else if let invoiceURL {
                            invoiceShareLink(invoiceURL)
                        }
                        #else
                        if let invoiceURL { invoiceShareLink(invoiceURL) }
                        #endif
                    }
                }
        }
        .task(id: requestID) {
            await model.load(using: loadReceipt)
        }
    }

    private func invoiceShareLink(_ url: URL) -> some View {
        ShareLink(item: url) {
            Label("Share", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
        }
        .wnIconButtonChrome(chrome: .container)
    }

    @ViewBuilder
    private var invoiceContent: some View {
        #if DEBUG
        if isSample {
            DonationReviewInvoice(payment: payment)
        } else {
            remoteInvoiceContent
        }
        #else
        remoteInvoiceContent
        #endif
    }

    #if DEBUG
    private var isSample: Bool {
        invoiceURL?.host == "donation-review.invalid"
    }
    #endif

    @ViewBuilder
    private var remoteInvoiceContent: some View {
        if let invoiceURL, !webFailed {
            DonationInvoiceWebView(url: invoiceURL, loading: $webLoading, failed: $webFailed)
                .id(requestID)
                .overlay {
                    if webLoading { ProgressView("Loading…") }
                }
        } else if model.state == .loading {
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Invoice unavailable", systemImage: "doc.text")
            } description: {
                Text(model.state == .pending
                     ? L10n.string("Your invoice is still being prepared.")
                     : L10n.string("Your payment succeeded. Please try again later to view the invoice."))
            } actions: {
                if model.canRetry {
                    Button("Try Again") {
                        model.retry()
                        webFailed = false
                        webLoading = true
                        requestID = UUID()
                    }
                }
            }
        }
    }
}

private struct DonationInvoiceWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DonationInvoiceWebView
        init(parent: DonationInvoiceWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            showFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            showFailure(error)
        }

        private func showFailure(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            parent.loading = false
            parent.failed = true
        }
    }
}

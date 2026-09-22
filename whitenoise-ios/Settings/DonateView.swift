import PassKit
import SwiftUI

struct DonateView: View {
    @Environment(\.openURL) private var openURL
    @State private var model: DonateViewModel
    @FocusState private var customAmountFocused: Bool

    private let donationURL = URL(
        string: "https://ipf.dev/donate/?utm_source=whitenoise_ios&utm_medium=app&utm_campaign=donations"
    )!

    @MainActor
    init() {
        _model = State(initialValue: DonateViewModel())
    }

    @MainActor
    init(model: DonateViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model

        Form {
            introductionSection
            cadenceSection(model: model)
            amountSection(model: model)
            disclosureSection
            applePaySection
            resultSection
            otherWaysSection
        }
        .localizedNavigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { customAmountFocused = false }
            }
        }
        .task { await model.prepareApplePay() }
        .onDisappear { model.cancel() }
    }

    private var introductionSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "heart")
                    .font(.largeTitle)
                    .foregroundStyle(.primary)
                Text("Support White Noise")
                    .font(.headline)
                Text("Your donation supports IPF's general fund, including White Noise.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func cadenceSection(model: DonateViewModel) -> some View {
        Section(L10n.string("Frequency")) {
            Picker("Frequency", selection: $model.cadence) {
                Text("One time").tag(DonationCadence.oneTime)
                Text("Monthly").tag(DonationCadence.monthly)
            }
            .pickerStyle(.segmented)
            .disabled(model.isProcessing)
            .onChange(of: model.cadence) { model.cadenceChanged() }
        }
    }

    private func amountSection(model: DonateViewModel) -> some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(DonatePresentation.presetAmountsCents, id: \.self) { cents in
                    amountButton(
                        title: DonatePresentation.formattedAmount(cents: cents),
                        isSelected: model.amountSelection == .preset(cents)
                    ) {
                        model.selectPreset(cents)
                        customAmountFocused = false
                    }
                }
                amountButton(
                    title: L10n.string("Custom"),
                    isSelected: model.amountSelection == .custom
                ) {
                    model.selectCustom()
                    customAmountFocused = true
                }
            }
            .padding(.vertical, 4)

            if model.amountSelection == .custom {
                HStack {
                    TextField("Amount in USD", text: $model.customAmountText)
                        .keyboardType(.decimalPad)
                        .focused($customAmountFocused)
                        .onChange(of: model.customAmountText) { model.customAmountChanged() }
                        .accessibilityLabel(L10n.string("Custom donation amount in USD"))
                    Text("USD")
                        .foregroundStyle(.secondary)
                }

                if let message = model.customAmountErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("donate.amount.error")
                }
            }
        } header: {
            Text("Amount")
        } footer: {
            Text("Choose an amount from $1 to $5,000 USD.")
        }
    }

    private func amountButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disabled(model.isProcessing)
    }

    private var disclosureSection: some View {
        Section {
            Text("IPF is a 501(c)(3) nonprofit. No goods or services are provided in exchange for your donation.")
            if model.cadence == .monthly {
                Text("Your selected amount will be charged every month until you cancel.")
                if let managementURL = model.managementURL {
                    Link("Manage monthly donation", destination: managementURL)
                }
            }
        } header: {
            Text("About your donation")
        } footer: {
            Text("Tax deductibility depends on your circumstances. Please consult your tax advisor.")
        }
    }

    @ViewBuilder
    private var applePaySection: some View {
        Section {
            switch model.availability {
            case .ready:
                PayWithApplePayButton(.donate, action: model.startDonation)
                    .payWithApplePayButtonStyle(.automatic)
                    .frame(minHeight: 50)
                    .disabled(!model.canDonate)
                    .accessibilityIdentifier("donate.apple-pay")
            case .setupRequired:
                PayWithApplePayButton(.setUp, action: model.openPaymentSetup)
                    .payWithApplePayButtonStyle(.automatic)
                    .frame(minHeight: 50)
                    .accessibilityIdentifier("donate.apple-pay-setup")
            case .unavailable:
                Text("Apple Pay isn't available on this device.")
                    .foregroundStyle(.secondary)
            case .notConfigured:
                if model.isPreparingApplePay {
                    ProgressView("Loading…")
                } else {
                    Text("Apple Pay donations aren't configured in this build.")
                        .foregroundStyle(.secondary)
                }
            }

            if model.isProcessing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Completing donation…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("donate.payment.error")
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if model.paymentSucceeded {
            Section(L10n.string("Donation complete")) {
                Label("Thank you for supporting IPF.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if let receiptURL = model.receiptURL {
                    Link("View receipt", destination: receiptURL)
                } else if model.receiptStatus == .pending {
                    Text("Your receipt is still being prepared.")
                        .foregroundStyle(.secondary)
                    Button("Check for receipt", action: model.checkReceipt)
                        .disabled(!model.canCheckReceipt)
                } else if model.receiptStatus == .failed || model.receiptCheckFailed {
                    Text("The donation succeeded, but the receipt isn't available yet.")
                        .foregroundStyle(.secondary)
                    Button("Check for receipt", action: model.checkReceipt)
                        .disabled(!model.canCheckReceipt)
                }

                if model.isCheckingReceipt {
                    ProgressView("Checking receipt…")
                }
            }
        }
    }

    private var otherWaysSection: some View {
        Section(L10n.string("Other ways to donate")) {
            Button {
                openURL(donationURL)
            } label: {
                Label("Open donation website", systemImage: "safari")
            }
        }
    }
}

import PassKit
import SwiftUI

struct DonateView: View {
    private let route: DonationScreenRoute

    init(route: DonationScreenRoute = .current()) {
        self.route = route
    }

    var body: some View {
        Group {
            switch route {
            case .applePay:
                ApplePayDonateView()
            case .website:
                WebsiteDonateView()
            case .unavailable:
                Form {
                    DonationIntroductionSection()
                    Section {
                        Text("Donations are temporarily unavailable. Please try again later.")
                    }
                }
            }
        }
        .localizedNavigationTitle("Donate")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WebsiteDonateView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            DonationIntroductionSection()
            Section {
                WNButton(title: "Donate", size: .standard) {
                    openURL(DonationScreenRoute.websiteURL)
                }
                .accessibilityAddTraits(.isLink)
                .accessibilityIdentifier("donate.website")
            }
        }
    }
}

private struct DonationIntroductionSection: View {
    var body: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "heart")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("Support White Noise")
                    .font(.headline)
                Text("Help the Internet Privacy Foundation (IPF), a nonprofit building tools for private communication.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }
}

private struct ApplePayDonateView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: DonateViewModel
    @State private var preparationAttempt = 0
    @State private var supportRefreshAttempt = 0
    @State private var presentedSuccess: DonationPayment?
    @State private var lastPresentedSuccessID: String?
    @State private var customPaymentHeight: CGFloat = 0
    @State private var customAmountFocused = false
    @ScaledMetric(relativeTo: .body) private var amountHeight = WNInputMetrics.height

    private enum ScrollTarget: Hashable {
        case customPayment
    }

    @MainActor
    init() {
        _model = State(initialValue: DonateViewModel())
    }

    var body: some View {
        ScrollViewReader { proxy in
            donationForm
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: customAmountFocused) {
                    revealCustomPayment(using: proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    // Focus changes before the keyboard finishes adjusting the form.
                    revealCustomPayment(using: proxy)
                }
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    geometry.visibleRect.size
                } action: { oldSize, newSize in
                    // Reveal after keyboard avoidance changes the visible viewport.
                    if newSize.height < oldSize.height || newSize.width != oldSize.width {
                        revealCustomPayment(using: proxy)
                    }
                }
                .onChange(of: customPaymentHeight) {
                    revealCustomPayment(using: proxy)
                }
        }
        .task(id: preparationAttempt) { await model.prepareApplePay() }
        .task(id: supportRefreshAttempt) { await model.refreshSupport() }
        .onDisappear { model.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshApplePayAvailability()
                if !model.accessSaveFailed { supportRefreshAttempt += 1 }
            }
        }
        .onChange(of: model.successfulPayment?.id, initial: true) { _, id in
            guard let id, id != lastPresentedSuccessID else { return }
            lastPresentedSuccessID = id
            presentedSuccess = model.successfulPayment
            if !model.accessSaveFailed { supportRefreshAttempt += 1 }
        }
        .sheet(item: $presentedSuccess) { payment in
            DonationSuccessView(cadence: payment.cadence)
        }
    }

    private var donationForm: some View {
        Form {
            DonationIntroductionSection()
            supportLoadingSection
            ForEach(model.support.monthlies, id: \.id) { monthly in
                Section {
                    DonationMonthlySupportCard(donation: monthly, managementURL: model.managementURL)
                        .wnGroupedCardRow(.only)
                }
            }
            donationSection
            historySection
            disclosureSection
        }
    }

    @ViewBuilder
    private var supportLoadingSection: some View {
        switch model.supportState {
        case .loading:
            Section {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            }
        case .failed:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.accessSaveFailed
                         ? L10n.string("Your donation succeeded, but history couldn't be saved on this device.")
                         : L10n.string("Your donation history couldn't be loaded. Please try again."))
                    if !model.accessSaveFailed {
                        Button("Try Again") { supportRefreshAttempt += 1 }
                    }
                }
            }
        case .accessExpired:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Donation history access is no longer available on this device.")
                    Text("A new donation won't restore earlier payments.")
                        .foregroundStyle(.secondary)
                }
            }
        case .none, .loaded:
            EmptyView()
        }
    }

    private func revealCustomPayment(using proxy: ScrollViewProxy) {
        guard customAmountFocused else { return }
        withAnimation(reduceMotion ? nil : .default) {
            proxy.scrollTo(ScrollTarget.customPayment, anchor: .bottom)
        }
    }

    private var donationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                cadencePicker
                if model.cadence == .monthly {
                    supportingText(L10n.string("Charged monthly until you cancel."), centered: true)
                }
            }
            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16))
            .wnGroupedCardRow(.first)
            amountPicker
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                .wnGroupedCardRow(.middle)
            VStack(alignment: .leading, spacing: 24) {
                customAmountField
                applePayControls
            }
            .padding(.bottom)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                customPaymentHeight = height
            }
            .id(ScrollTarget.customPayment)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .wnGroupedCardRow(.last)
        }
        .listRowSeparator(.hidden)
    }

    private var cadencePicker: some View {
        @Bindable var model = model

        return Picker("Frequency", selection: $model.cadence) {
            Text("One time").tag(DonationCadence.oneTime)
            Text("Monthly").tag(DonationCadence.monthly)
        }
        .wnPalettePicker()
        .frame(maxWidth: .infinity)
        .disabled(model.isProcessing)
        .onChange(of: model.cadence) { model.cadenceChanged() }
    }

    private var amountPicker: some View {
        VStack(spacing: 12) {
            ForEach(DonatePresentation.presetAmountsCents, id: \.self) { cents in
                let isSelected = model.amountSelection == .preset(cents)

                Button {
                    model.selectPreset(cents)
                    customAmountFocused = false
                } label: {
                    HStack {
                        Text(DonatePresentation.formattedAmount(cents: cents))
                            .font(.body.weight(.medium))
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, WNInputMetrics.leadingInset)
                    .padding(.vertical, 12)
                    .frame(minHeight: amountHeight)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(
                            isSelected ? Color.primary : Color(.separator),
                            lineWidth: isSelected ? 2 : 1
                        )
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("donate.amount.\(cents)")
                .disabled(model.isProcessing)
            }
        }
    }

    private var customAmountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            DonationAmountInput(
                text: model.customAmountText,
                focused: $customAmountFocused,
                decideEdit: model.decideAmountEdit,
                onChange: model.updateCustomAmount
            )
            .disabled(model.isProcessing)

            if let message = model.customAmountErrorMessage {
                supportingText(message, isError: true)
                    .accessibilityIdentifier("donate.amount.error")
            }
        }
    }

    private var disclosureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("About your donation")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("IPF is a 501(c)(3) nonprofit incorporated in Wyoming that builds tools to help people communicate privately. We develop White Noise and Marmot, the open messaging protocol behind it. Your donation supports this work and our belief that private conversations should be available to everyone.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color(uiColor: .quaternarySystemFill).opacity(0.5))
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = model.displayedPayments
        if !history.payments.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thank you for your support")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Recent billing activity")
                        .foregroundStyle(.secondary)
                }
                .wnGroupedCardRow(.first)

                ForEach(history.recentPayments) { donation in
                    DonationHistoryRow(donation: donation)
                        .wnGroupedCardRow(.middle)
                }

                NavigationLink {
                    DonationHistoryView(model: model)
                        .wnBackButton()
                } label: {
                    Text("See all billing activity")
                }
                .wnGroupedCardRow(.last)
            }
        }
    }

    @ViewBuilder
    private var applePayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.availability {
            case .ready:
                DonationApplePayButton(type: .donate) {
                    customAmountFocused = false
                    model.startDonation()
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .disabled(!model.canDonate)
                .accessibilityIdentifier("donate.apple-pay")
            case .setupRequired:
                DonationApplePayButton(type: .setUp, action: model.openPaymentSetup)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityIdentifier("donate.apple-pay-setup")
            case .unavailable:
                Button {} label: {
                    Text("Apple Pay unavailable")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(uiColor: .systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityIdentifier("donate.apple-pay-unavailable")
            case .notConfigured:
                if model.isPreparingApplePay {
                    WNButton(title: "Donate", size: .standard, isLoading: true) {}
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .accessibilityLabel("Loading…")
                        .accessibilityIdentifier("donate.apple-pay-loading")
                } else {
                    supportingText(L10n.string("Donations are temporarily unavailable. Please try again later."))
                    if model.applePayPreparationFailed {
                        Button("Try Again") { preparationAttempt += 1 }
                            .font(.footnote)
                            .padding(.horizontal, WNInputMetrics.leadingInset)
                    }
                }
            }

            if let errorMessage = model.errorMessage {
                supportingText(errorMessage, isError: true)
                    .accessibilityIdentifier("donate.payment.error")
            }
        }
    }

    private func supportingText(_ message: String, isError: Bool = false, centered: Bool = false) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .multilineTextAlignment(centered ? .center : .leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.horizontal, WNInputMetrics.leadingInset)
    }
}

private struct DonationApplePayButton: UIViewRepresentable {
    let type: PKPaymentButtonType
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> CapsulePaymentButton {
        let button = CapsulePaymentButton(paymentButtonType: type, paymentButtonStyle: .automatic)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: CapsulePaymentButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate() { action() }
    }

    final class CapsulePaymentButton: PKPaymentButton {
        override func layoutSubviews() {
            super.layoutSubviews()
            let radius = bounds.height / 2
            if cornerRadius != radius { cornerRadius = radius }
        }
    }
}

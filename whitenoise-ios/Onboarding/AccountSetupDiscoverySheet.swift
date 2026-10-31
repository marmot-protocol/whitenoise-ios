import MarmotKit
import SwiftUI

struct AccountSetupDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    let step: OnboardingStepFfi
    var onFailure: ((AccountSetupFailure) -> Void)?
    @State private var relay = ""
    @State private var fieldError: String?
    @State private var lookupError: String?
    @State private var isSubmitting = false

    private var isBusy: Bool { model.isBusy || isSubmitting }

    var body: some View {
        AccountSetupRecoveryLayout(title: step == .relays ? L10n.string("Find Relay Settings") : L10n.string("Find Your Settings"), isBusy: isBusy, inlineActions: true) {
            Section {
                AccountSetupRecoveryCallout(
                    title: isBusy ? (step == .relays ? "Find Relay Settings" : "Find Your Settings") : lookupError == nil ? "Search a relay you’ve used before" : "Couldn’t find your relay settings",
                    symbol: lookupError == nil ? "magnifyingglass" : "exclamationmark.circle",
                    isError: lookupError != nil, isLoading: isBusy
                ) {
                    if isBusy {
                        Text("Searching…")
                    } else if let lookupError {
                        Text(lookupError)
                    } else if step == .relays {
                        Text("Enter a relay address from another app where you use this profile. We’ll look there for your existing relay settings.")
                    } else {
                        Text("Choose a relay you’ve used with this profile. We’ll look there for your existing settings without publishing anything.")
                    }
                    Divider()
                    Text("Searching won’t publish changes to your profile or replace your relay list.")
                }
            }
            Section {
                TextField("wss://relay.example.com", text: $relay)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(search)
                    .keyboardType(.URL)
                    .accessibilityLabel("Relay URL")
                    .disabled(isBusy)
                    .onChange(of: relay) {
                        fieldError = nil
                        lookupError = nil
                    }
            } header: {
                Text("Relay URL")
            } footer: {
                if let fieldError { Text(fieldError).foregroundStyle(.red) }
            }
        } actions: {
            WNOnboardingButton(title: lookupError == nil ? "Search Relay" : "Try Again", isLoading: isSubmitting, action: search)
                .disabled(isBusy || !model.isConnected || relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func search() {
        guard !isBusy else { return }
        guard let values = AccountSetupInput.relays(relay), values.count == 1 else {
            fieldError = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")
            return
        }
        guard let operation = model.send(.discovery(values)) else {
            lookupError = model.errorMessage ?? L10n.string("Setup updates stopped. Try again to continue.")
            return
        }
        fieldError = nil
        isSubmitting = true
        Task {
            await operation.value
            if let failure = AccountSetupDiscoveryOutcome.failure(model.failure, isConnected: model.isConnected) {
                isSubmitting = false
                lookupError = failure.message
                onFailure?(failure)
            } else {
                dismiss()
            }
        }
    }
}

nonisolated enum AccountSetupDiscoveryOutcome {
    static func failure(_ failure: AccountSetupFailure?, isConnected: Bool) -> AccountSetupFailure? {
        switch failure {
        case .operation: .discovery
        case .some(let failure): failure
        case nil: isConnected ? nil : .updatesStopped
        }
    }
}

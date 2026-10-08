import MarmotKit
import SwiftUI

struct AccountSetupRelayEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AccountSetupModel
    var step: OnboardingStepFfi = .relays
    @Binding var draft: AccountSetupRelayDraft
    var onFailure: ((String) -> Void)?
    @State private var editingEntry: AccountSetupRelayDraft.Entry?
    @State private var error: String?
    @State private var invalidEntryID: UUID?
    @State private var isSubmitting = false
    @State private var operationFailed = false

    private var isBusy: Bool { model.isBusy || isSubmitting }

    var body: some View {
        AccountSetupRecoveryLayout(title: L10n.string("Edit Relays"), isBusy: isBusy) {
            Section {
                AccountSetupRecoveryCallout(
                    title: isBusy ? "Your relay changes" : error == nil ? "Choose your relay list" : "Couldn’t prepare your relay changes",
                    symbol: error == nil ? "network" : "exclamationmark.circle", isError: error != nil, isLoading: isBusy
                ) {
                    if isBusy {
                        Text("Preparing changes…")
                    } else if let error {
                        Text(error)
                    } else {
                        if step == .inboxRelays {
                            Text("Inbox relays receive invitations to new chats and groups.")
                        } else {
                            Text("Add the relays you want to use. Keep at least one write relay so your profile can publish information.")
                        }
                    }
                    Divider()
                    if step == .inboxRelays {
                        Text("This replaces your message inbox relay list, including entries you leave out. Nothing is published until you review and approve it.")
                    } else {
                        Text("This will replace your public relay list, including entries you leave out. You’ll review the full list before anything is published.")
                    }
                }
            }
            Section {
                ForEach(draft.entries) { entry in
                    Button { editingEntry = entry } label: {
                        HStack {
                            AccountSetupRelaySummary(entry: entry, showsRoles: step == .relays)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(isBusy)
                    if invalidEntryID == entry.id {
                        Text("Edit this relay to check its address and uses.")
                            .font(.subheadline).foregroundStyle(.red)
                    }
                }
                .onDelete { offsets in
                    draft.entries.remove(atOffsets: offsets)
                    clearValidation()
                }
                .deleteDisabled(isBusy)
                Button {
                    editingEntry = .init(writes: step == .relays)
                } label: {
                    Label("Add Relay", systemImage: "plus.circle")
                }
                .disabled(isBusy || draft.entries.count >= 16)
            } header: {
                Text("Your new relay list")
            } footer: {
                if step == .relays {
                    Text("Read relays find public information. Write relays publish your public information. A relay can do both.")
                }
            }
        } actions: {
            WNOnboardingButton(title: operationFailed ? "Try Again" : "Review Changes", isLoading: isSubmitting, action: submit)
                .disabled(isBusy || !model.isConnected || draft.entries.isEmpty)
        }
        .sheet(item: $editingEntry) { entry in
            AccountSetupRelayEntryEditor(
                entry: entry,
                showsRoles: step == .relays,
                isNew: !draft.entries.contains(where: { $0.id == entry.id }),
                onRemove: {
                    draft.entries.removeAll { $0.id == entry.id }
                    clearValidation()
                }
            ) { updated in
                if let index = draft.entries.firstIndex(where: { $0.id == updated.id }) {
                    draft.entries[index] = updated
                } else {
                    draft.entries.append(updated)
                }
                clearValidation()
            }
            .appAppearance()
        }
    }

    private func clearValidation() {
        error = nil
        invalidEntryID = nil
        operationFailed = false
    }

    private func submit() {
        guard !isBusy else { return }
        let selection: AccountSetupRelayDraft.Selection
        do {
            selection = try draft.selection(for: step)
        } catch let validation as AccountSetupRelayDraft.ValidationError {
            invalidEntryID = nil
            switch validation {
            case .invalidAddress(let id), .missingRole(let id):
                invalidEntryID = id
                error = L10n.string("Check the highlighted relay before continuing.")
            case .missingWriteRelay:
                error = L10n.string("Choose at least one write relay so your profile can publish information.")
            case .missingInboxRelay:
                error = L10n.string("Add a relay before continuing.")
            case .tooManyRelays:
                error = L10n.string("The relay list is too large.")
            }
            return
        } catch { return }
        guard let operation = model.send(.editRelays(step, reads: selection.reads, writes: selection.writes)) else { return }
        if !operationFailed { clearValidation() }
        isSubmitting = true
        Task {
            await operation.value
            if model.errorMessage == nil, model.isConnected,
               model.snapshot.proposal?.step == step,
               model.snapshot.steps.first(where: { $0.step == step })?.actions.contains(.approveRepair) == true {
                dismiss()
            } else {
                isSubmitting = false
                operationFailed = true
                let message = model.errorMessage ?? L10n.string("Couldn’t finish this step. Try again.")
                error = message
                onFailure?(message)
            }
        }
    }
}

private struct AccountSetupRelayEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: AccountSetupRelayDraft.Entry
    let showsRoles: Bool
    let isNew: Bool
    let onRemove: () -> Void
    let onSave: (AccountSetupRelayDraft.Entry) -> Void
    @State private var showsValidation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wss://relay.example.com", text: $entry.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Relay URL")
                } header: {
                    Text("Relay URL")
                } footer: {
                    if showsValidation, entry.normalizedAddress == nil {
                        Text("Enter a valid relay URL, like wss://relay.example.com.").foregroundStyle(.red)
                    }
                }
                if showsRoles {
                    Section {
                        Toggle(isOn: $entry.reads) {
                            VStack(alignment: .leading) {
                                Text("Read")
                                Text("Find public information on this relay.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(isOn: $entry.writes) {
                            VStack(alignment: .leading) {
                                Text("Write")
                                Text("Publish your public information to this relay.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Use For")
                    } footer: {
                        if showsValidation, !entry.reads && !entry.writes {
                            Text("Choose Read, Write, or both.").foregroundStyle(.red)
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button("Remove Relay", role: .destructive) {
                            onRemove()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Relay" : "Edit Relay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Done") {
                        showsValidation = true
                        guard let address = entry.normalizedAddress, !showsRoles || entry.reads || entry.writes else { return }
                        entry.address = address
                        onSave(entry)
                        dismiss()
                    }
                    .wnPrimaryButtonStyle()
                    .wnButtonChrome()
                    .disabled(entry.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AccountSetupRelaySummary: View {
    let address: String
    var entry: AccountSetupRelayDraft.Entry?
    var showsRoles = true

    init(address: String) { self.address = address }
    init(entry: AccountSetupRelayDraft.Entry, showsRoles: Bool = true) {
        self.showsRoles = showsRoles
        self.address = entry.address
        self.entry = entry
    }

    private var normalized: String? { AccountSetupInput.proposalRelays([address])?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: normalized.flatMap { URL(string: $0)?.host } ?? L10n.string("Relay"))
                .font(.body)
            Text(verbatim: ContentSanitizer.relayDisplayLine(address, maxLength: 512) ?? L10n.string("Invalid relay address"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if normalized == nil {
                Text("Invalid relay address").font(.subheadline).foregroundStyle(.red)
            }
            if showsRoles, let entry {
                Text(entry.reads && entry.writes ? "Read and write" : entry.writes ? "Write only" : entry.reads ? "Read only" : "Choose a use")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

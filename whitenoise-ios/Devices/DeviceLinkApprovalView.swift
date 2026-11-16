import MarmotKit
import SwiftUI

/// On a device already signed in: a new device asks to be linked. The user
/// compares the emoji, names the device, and links it or says Not Now.
struct DeviceLinkApprovalView: View {
    let promptID: String

    @Environment(AppState.self) private var appState
    @State private var label = L10n.string("New Device")
    @State private var ownLabel = LinkThisDeviceCopy.defaultDeviceName
    @State private var addToAllChats = true
    @State private var bringHistory = true
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showsMismatchAlert = false

    private var store: DeviceLinkStore { appState.deviceLinks }
    private var prompt: DeviceLinkPromptFfi? { store.prompt(promptID) }

    var body: some View {
        NavigationStack {
            Form {
                if let prompt {
                    content(prompt)
                } else {
                    Section {
                        Text("This request is no longer active.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .localizedNavigationTitle("Link New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let prompt, DeviceLinkPromptPresentation.canDecline(prompt.state) {
                        Button("Not Now") {
                            run {
                                try await store.decline(promptID: promptID, using: appState)
                                store.sheetDismissed()
                            }
                        }
                        .disabled(busy)
                    } else {
                        Button("Close") { store.sheetDismissed() }
                    }
                }
            }
            .alert("Device Not Linked", isPresented: $showsMismatchAlert) {
                Button("OK") {
                    Task {
                        // The request may already have ended; either way it isn't linked.
                        try? await store.decline(promptID: promptID, using: appState)
                        store.sheetDismissed()
                    }
                }
            } message: {
                Text("If you didn’t try to link a device, someone else may have your private key. Review sign-ins in Settings → Devices.")
            }
        }
        // Keep the user's decision explicit while the code is up.
        .interactiveDismissDisabled(prompt.map { DeviceLinkPromptPresentation.canDecline($0.state) } ?? false)
    }

    @ViewBuilder
    private func content(_ prompt: DeviceLinkPromptFfi) -> some View {
        switch prompt.state {
        case .comparing(let code):
            Section {
                DeviceLinkStatusHeader(
                    systemImage: "eyes",
                    title: L10n.string("Compare Emoji"),
                    message: L10n.string("A device signed in to your profile wants to link. Only link it if it shows the same emoji, in the same order.")
                )
                .padding(.vertical, 8)
                DeviceLinkCodeView(code: code)
            }
            Section {
                TextField("Device name", text: $label)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                WNToggle("Add to All My Chats", isOn: $addToAllChats)
                WNToggle("Bring Chat History", isOn: $bringHistory)
            } header: {
                Text("New Device")
            } footer: {
                if DeviceLabelInput.isTooLong(label) {
                    Text("Enter a shorter device name.").foregroundStyle(.red)
                } else {
                    Text("Add to All My Chats adds the new device to the chats your devices are in. Bring Chat History sends it those chats’ messages.")
                }
            }
            if needsOwnName {
                Section {
                    TextField(LinkThisDeviceCopy.thisDeviceNameLabel, text: $ownLabel)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: {
                    Text("This Device")
                } footer: {
                    if DeviceLabelInput.isTooLong(ownLabel) {
                        Text("Enter a shorter device name.").foregroundStyle(.red)
                    } else {
                        Text("Your other devices show this device by this name.")
                    }
                }
            }
            Section {
                // One row, so the list doesn't butt two inset-free rows together.
                VStack(spacing: 12) {
                    WNButton(title: "They Match — Link Device", size: .standard, isLoading: busy) {
                        guard let label = DeviceLabelInput.validated(label) else { return }
                        let thisDeviceLabel = needsOwnName ? DeviceLabelInput.validated(ownLabel) : nil
                        guard !needsOwnName || thisDeviceLabel != nil else { return }
                        run {
                            try await store.link(
                                promptID: promptID, label: label, addToAllChats: addToAllChats,
                                bringHistory: bringHistory, thisDeviceLabel: thisDeviceLabel, using: appState
                            )
                        }
                    }
                    .disabled(
                        DeviceLabelInput.validated(label) == nil
                            || (needsOwnName && DeviceLabelInput.validated(ownLabel) == nil)
                    )
                    WNButton(title: "They Don’t Match", emphasis: .secondary, size: .standard) {
                        showsMismatchAlert = true
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .disabled(busy)
        case .preparing:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "hourglass",
                    title: L10n.string("Checking the New Device"),
                    message: L10n.string("A device signed in to your profile wants to link. The emoji appear in a moment."),
                    showsProgress: true
                ),
                doneTitle: nil
            )
        case .linking:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "arrow.triangle.2.circlepath",
                    title: L10n.string("Linking…"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state),
                    showsProgress: true
                )
            )
        case .linked:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "checkmark.circle.fill", tint: .green,
                    title: L10n.string("Device Linked"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state)
                ),
                doneTitle: "Done"
            )
        case .addedElsewhere:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "checkmark.circle", tint: .green,
                    title: L10n.string("Already Linked"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state)
                ),
                doneTitle: "Done"
            )
        case .cannotLink(let missing):
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "exclamationmark.triangle.fill", tint: .orange,
                    title: L10n.string("Can’t Link This Device"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state)
                ),
                detail: missing.isEmpty ? nil : missing.joined(separator: ", "),
                doneTitle: nil
            )
        case .competingRequests, .rateLimited, .tooManyDevices:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "exclamationmark.triangle.fill", tint: .orange,
                    title: L10n.string("Can’t Link Right Now"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state)
                ),
                doneTitle: nil
            )
        case .ended:
            statusSection(
                header: DeviceLinkStatusHeader(
                    systemImage: "exclamationmark.triangle.fill", tint: .orange,
                    title: L10n.string("Not Linked"),
                    message: DeviceLinkPromptPresentation.summary(prompt.state)
                )
            )
        }
    }

    /// The status card, then its button in a section of its own, so the card
    /// keeps its rounded corners and the button sits below it. A request still
    /// waiting on this device has no button: Not Now is the way out.
    @ViewBuilder
    private func statusSection(
        header: DeviceLinkStatusHeader,
        detail: String? = nil,
        doneTitle: LocalizedStringKey? = "Close"
    ) -> some View {
        Section {
            header.padding(.vertical, 12)
            if let detail {
                Text(verbatim: detail)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        if let doneTitle {
            Section {
                WNButton(title: doneTitle, emphasis: .secondary, size: .standard) { store.sheetDismissed() }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    /// This device has no name yet, as before its first link: ask for one too,
    /// so the new device never lists it unnamed.
    private var needsOwnName: Bool {
        store.thisDevice?.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

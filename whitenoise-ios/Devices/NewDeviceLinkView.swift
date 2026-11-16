import MarmotKit
import SwiftUI

/// On a new device: ask a device already signed in to this profile to link
/// this one, compare the emoji, and wait for the other device to add it.
struct NewDeviceLinkView: View {
    @Environment(AppState.self) private var appState
    @State private var started = false
    @State private var busy = false
    @State private var errorMessage: String?
    /// The user said the emoji differ; the end reason alone reads "cancelled".
    @State private var reportedMismatch = false

    private var store: DeviceLinkStore { appState.deviceLinks }

    private var step: NewDeviceLinkStep {
        started ? store.newDeviceStep : .opening(store.snapshot?.newDevice)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    content
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                actions
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 560)
            }
            .localizedNavigationTitle("Link This Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { store.sheetDismissed() }
                }
            }
            .animation(.smooth(duration: 0.2), value: step)
        }
        .onAppear {
            if step != .intro { started = true }
        }
        .task {
            if store.consumeStartsLinkOnPresent() { run { try await start() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro:
            DeviceLinkStatusHeader(
                systemImage: "laptopcomputer.and.iphone",
                title: L10n.string("Link to Another Device"),
                message: L10n.string("Bring your chats to this device from a device where you’re already signed in to this profile.")
            )
            VStack(alignment: .leading, spacing: 14) {
                instruction(1, L10n.string("Open White Noise on your other device."))
                instruction(2, L10n.string("A request to link this device appears there."))
                instruction(3, L10n.string("Check that both devices show the same emoji, then confirm on both."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.deviceGroupStalled == false, store.hasDeviceGroup {
                Text("This device is already linked to other devices. Linking it to another device moves it to that device’s list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .waitingForAnswer:
            DeviceLinkStatusHeader(
                systemImage: "hourglass",
                title: L10n.string("Waiting for Your Other Device"),
                message: L10n.string("Open White Noise on a device that’s already signed in to this profile. It needs to be online, with device linking on. The request appears there and expires after 10 minutes."),
                showsProgress: true
            )
        case .comparing(let code):
            DeviceLinkStatusHeader(
                systemImage: "eyes",
                title: L10n.string("Compare Emoji"),
                message: L10n.string("Check that your other device shows the same emoji, in the same order.")
            )
            DeviceLinkCodeView(code: code)
        case .waitingForOtherDevice:
            DeviceLinkStatusHeader(
                systemImage: "hourglass",
                title: L10n.string("Confirm on Your Other Device"),
                message: L10n.string("Tap Link Device on your other device to finish."),
                showsProgress: true
            )
        case .joining:
            DeviceLinkStatusHeader(
                systemImage: "arrow.triangle.2.circlepath",
                title: L10n.string("Linking…"),
                message: L10n.string("Your other device is adding this one. Keep White Noise open on both devices."),
                showsProgress: true
            )
        case .linked:
            DeviceLinkStatusHeader(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                title: L10n.string("Device Linked"),
                message: L10n.string("Your chats appear here as your other device adds this one to them.")
            )
            if let thisDevice = store.thisDevice {
                NameThisDeviceField(device: thisDevice)
            }
        case .ended(let reason):
            DeviceLinkStatusHeader(
                systemImage: reportedMismatch ? "exclamationmark.shield.fill" : "xmark.circle.fill",
                tint: .orange,
                title: L10n.string("Not Linked"),
                message: reportedMismatch
                    ? L10n.string("The devices weren’t linked. If you didn’t expect different emoji, someone else may have your private key.")
                    : DeviceLinkEndPresentation.message(for: reason)
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            switch step {
            case .intro:
                WNButton(title: "Start Linking", isLoading: busy) { run { try await start() } }
            case .waitingForAnswer, .waitingForOtherDevice, .joining:
                WNButton(title: "Cancel Linking", emphasis: .secondary, isLoading: busy) {
                    run { try await store.cancelLink(using: appState) }
                }
            case .comparing:
                WNButton(title: "They Match", isLoading: busy) {
                    run { try await store.confirmMatch(using: appState) }
                }
                WNButton(title: "They Don’t Match", emphasis: .secondary) {
                    run {
                        reportedMismatch = true
                        try await store.cancelLink(using: appState)
                    }
                }
            case .linked:
                WNButton(title: "Done") { store.sheetDismissed() }
            case .ended:
                WNButton(title: "Try Again", isLoading: busy) { run { try await start() } }
                WNButton(title: "Close", emphasis: .secondary) { store.sheetDismissed() }
            }
        }
        .disabled(busy)
    }

    private func start() async throws {
        reportedMismatch = false
        try await store.startLink(using: appState)
        started = true
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

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemFill), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// On the new device after linking: replace the name the approving device gave
/// it. Saving renames it in the roster, so every device shows the new name.
private struct NameThisDeviceField: View {
    let device: LinkedDeviceFfi

    @Environment(AppState.self) private var appState
    @State private var draft: String?
    @State private var saving = false
    @State private var saved = false
    @State private var errorMessage: String?

    var body: some View {
        let text = Binding(get: { draft ?? Self.initialName(device.label) }, set: { draft = $0; saved = false })
        VStack(alignment: .leading, spacing: 10) {
            Text(LinkThisDeviceCopy.nameThisDeviceTitle)
                .font(.headline)
            WNInput(placeholder: LinkThisDeviceCopy.defaultDeviceName, text: text, autocapitalization: .words,
                    disablesAutocorrection: false)
            if DeviceLabelInput.isTooLong(text.wrappedValue) {
                Text("Enter a shorter device name.").font(.footnote).foregroundStyle(.red)
            } else if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            if saved {
                Label("Name saved", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else {
                WNButton(title: "Save Name", emphasis: .secondary, size: .standard, isLoading: saving) {
                    save(text.wrappedValue)
                }
                .disabled(DeviceLabelInput.validated(text.wrappedValue) == nil || saving)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The approving device's default says nothing about this one: offer its kind instead.
    private static func initialName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == L10n.string("New Device") ? LinkThisDeviceCopy.defaultDeviceName : trimmed
    }

    private func save(_ text: String) {
        guard let label = DeviceLabelInput.validated(text), !saving else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await appState.deviceLinks.rename(slotIdHex: device.slotIdHex, label: label, using: appState)
                saved = true
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

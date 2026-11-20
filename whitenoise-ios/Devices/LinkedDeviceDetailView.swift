import MarmotKit
import SwiftUI

/// One linked device: its name, what it does when linked to chats, and removal.
/// Values shown are the roster's; an edit shows as pending until MDK reports it.
struct LinkedDeviceDetailView: View {
    let slotIdHex: String

    private enum Setting: Hashable {
        case addToAllChats, bringHistory, keepWhileInactive
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft: String?
    @State private var pending: [Setting: Bool] = [:]
    @State private var busyKey: String?
    @State private var errorMessage: String?
    @State private var confirmsRemoval = false

    private var store: DeviceLinkStore { appState.deviceLinks }
    private var device: LinkedDeviceFfi? { store.device(slotIdHex) }

    var body: some View {
        Form {
            if let device {
                nameSection(device)
                infoSection(device)
                if LinkedDevicePresentation.offersInactiveChoice(device) { inactiveSection(device) }
                settingsSection(device)
                if LinkedDevicePresentation.canRemove(device) { removeSection(device) }
            } else {
                Section {
                    Text("This device is no longer in your device list.")
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
        .navigationTitle(device.map(LinkedDevicePresentation.name) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: device) { previous, current in
            // A removed device leaves the roster: go back to the list.
            guard let current else {
                if previous != nil { dismiss() }
                return
            }
            // Drop a pending edit once the roster agrees with it.
            pending = pending.filter { setting, value in value != Self.value(setting, of: current) }
        }
        .alert(
            L10n.formatted("Remove “%@”?", device.map(LinkedDevicePresentation.name) ?? ""),
            isPresented: $confirmsRemoval
        ) {
            Button("Remove", role: .destructive) {
                run("remove") { try await store.remove(slotIdHex: slotIdHex, using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from your devices and from every chat it can be removed from, and stops getting messages in those chats. A chat admin can remove it from any chat that still includes it. To use it again, sign in on it and link it anew.")
        }
    }

    private func nameSection(_ device: LinkedDeviceFfi) -> some View {
        let draft = Binding(get: { nameDraft ?? device.label }, set: { nameDraft = $0 })
        let changed = nameDraft.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) != device.label } ?? false
        let tooLong = DeviceLabelInput.isTooLong(draft.wrappedValue)
        return Section {
            HStack {
                TextField("Device name", text: draft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit { if changed && !tooLong { saveName(draft.wrappedValue) } }
                if changed {
                    Button("Save") { saveName(draft.wrappedValue) }
                        .disabled(tooLong || busyKey == "rename")
                }
            }
        } header: {
            Text("Name")
        } footer: {
            if tooLong {
                Text("Enter a shorter device name.").foregroundStyle(.red)
            } else {
                Text("Your devices see this name. Leave it empty to clear it.")
            }
        }
    }

    private func infoSection(_ device: LinkedDeviceFfi) -> some View {
        Section {
            if let client = LinkedDevicePresentation.clientLine(device) {
                LabeledContent("App", value: client)
            }
            LabeledContent("Linked") {
                Text(DeviceTimePresentation.date(unixSeconds: device.linkedAt), format: .dateTime.day().month().year())
            }
            if let lastActive = LinkedDevicePresentation.lastActive(device) {
                LabeledContent("Activity", value: lastActive)
            }
            if let status = LinkedDevicePresentation.status(device) {
                LabeledContent("Status", value: status)
            }
            if let linkedBy = device.linkedBySlotIdHex, let linker = store.device(linkedBy) {
                LabeledContent("Linked By", value: LinkedDevicePresentation.name(linker))
            }
        }
    }

    private func inactiveSection(_ device: LinkedDeviceFfi) -> some View {
        Section {
            Text("Your devices haven’t heard from this one for about a month. Unless you keep it, it’s removed after about three months.")
                .font(.subheadline)
            Button("Keep This Device") { set(.keepWhileInactive, true, device) }
            Button("Remove This Device", role: .destructive) { confirmsRemoval = true }
        }
        .disabled(busyKey != nil)
    }

    private func settingsSection(_ device: LinkedDeviceFfi) -> some View {
        Section {
            WNToggle("Add to All My Chats", isOn: binding(.addToAllChats, device))
            WNToggle("Bring Chat History", isOn: binding(.bringHistory, device))
            if !device.isThisDevice {
                WNToggle("Keep While Inactive", isOn: binding(.keepWhileInactive, device))
            }
        } header: {
            Text("Chats")
        } footer: {
            Text("Add to All My Chats lets your devices add this one to chats it isn’t in yet; turning it off doesn’t remove it from any. Bring Chat History sends it earlier messages when it’s added. Keep While Inactive stops your devices removing it after a long time away.")
        }
        .disabled(busyKey != nil)
    }

    private func removeSection(_ device: LinkedDeviceFfi) -> some View {
        Section {
            Button("Remove Device", role: .destructive) { confirmsRemoval = true }
                .disabled(busyKey == "remove")
        } footer: {
            Text("To remove this device you’re using, sign out instead.")
        }
    }

    // MARK: - Actions

    private func binding(_ setting: Setting, _ device: LinkedDeviceFfi) -> Binding<Bool> {
        Binding(
            get: { pending[setting] ?? Self.value(setting, of: device) },
            set: { set(setting, $0, device) }
        )
    }

    private func set(_ setting: Setting, _ value: Bool, _ device: LinkedDeviceFfi) {
        guard busyKey == nil else { return }
        pending[setting] = value
        run("setting") {
            do {
                try await store.updateSettings(
                    slotIdHex: slotIdHex,
                    addToAllChats: setting == .addToAllChats ? value : nil,
                    bringHistory: setting == .bringHistory ? value : nil,
                    keepWhileInactive: setting == .keepWhileInactive ? value : nil,
                    using: appState
                )
            } catch {
                pending[setting] = nil
                throw error
            }
        }
    }

    private static func value(_ setting: Setting, of device: LinkedDeviceFfi) -> Bool {
        switch setting {
        case .addToAllChats: device.addToAllChats
        case .bringHistory: device.bringHistory
        case .keepWhileInactive: device.keepWhileInactive
        }
    }

    private func saveName(_ text: String) {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !DeviceLabelInput.isTooLong(label) else { return }
        run("rename") {
            try await store.rename(slotIdHex: slotIdHex, label: label, using: appState)
            // Keep anything typed while the rename ran.
            if nameDraft == text { nameDraft = nil }
        }
    }

    private func run(_ key: String, _ action: @escaping () async throws -> Void) {
        guard busyKey == nil else { return }
        busyKey = key
        errorMessage = nil
        Task {
            defer { busyKey = nil }
            do {
                try await action()
            } catch {
                errorMessage = UserFacingError.message(for: error)
            }
        }
    }
}

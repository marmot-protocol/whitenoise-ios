import SwiftUI
import MarmotKit

struct AttachmentStorageSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var policy: AttachmentDownloadPolicyFfi?
    @State private var reserveMiB = 256
    @State private var transferMiB = 64
    @State private var saving = false
    @State private var error: String?
    @State private var reload = 0

    var body: some View {
        Form {
            if policy != nil {
                Section {
                    Stepper(value: $reserveMiB, in: 0...8192, step: 256) {
                        LabeledContent("Keep disk space free", value: size(reserveMiB))
                    }
                    Stepper(value: $transferMiB, in: 1...512, step: 1) {
                        LabeledContent("Automatic download size limit", value: size(transferMiB))
                    }
                } footer: {
                    Text("Limits apply to this profile. A download waits when it would leave less free space than this, and continues when you free up space. To remove attachments or choose how long to keep them, go to Manage Storage. Automatic downloads also follow your media and network preferences.")
                }
                Button("Save") { save() }.disabled(saving)
            } else if error == nil { ProgressView() }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { reload &+= 1 }
            }
        }
        .disabled(saving)
        .navigationTitle("Download Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(reload)") {
            policy = nil
            error = nil
            guard let account = appState.activeAccountRef else { return }
            do {
                let client = try appState.currentMarmotClient()
                let value = try await client.marmot.attachmentDownloadPolicy(accountRef: account)
                try Task.checkCancellation()
                guard appState.activeAccountRef == account, appState.client === client else { return }
                policy = value
                reserveMiB = Int(value.diskReserve / 1_048_576)
                transferMiB = Int(value.transferLimit / 1_048_576)
            } catch is CancellationError { return }
            catch { self.error = L10n.string("Couldn't load download settings.") }
        }
    }

    private func size(_ mebibytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(mebibytes) * 1_048_576, countStyle: .binary)
    }

    private func save() {
        guard !saving, let account = appState.activeAccountRef else { return }
        saving = true
        error = nil
        let reserve = UInt64(reserveMiB) * 1_048_576
        let transfer = UInt64(transferMiB) * 1_048_576
        Task { @MainActor in
            defer { saving = false }
            do {
                let client = try appState.currentMarmotClient()
                // Read the current gate so editing quotas does not undo a network change.
                let current = try await client.marmot.attachmentDownloadPolicy(accountRef: account)
                let next = AttachmentDownloadLimits.applying(diskReserve: reserve, transferLimit: transfer,
                                                             to: current)
                try await AttachmentPolicyBridge.synchronize(client, updatedLimits: (account, next))
                guard appState.activeAccountRef == account, appState.client === client else { return }
                policy = next
                appState.present(.success(L10n.string("Download settings saved")))
            } catch {
                guard appState.activeAccountRef == account else { return }
                self.error = L10n.string("Couldn't save download settings.")
            }
        }
    }
}

nonisolated enum AttachmentDownloadLimits {
    /// Since MarmotKit 0.14.0 `retainedBytes` no longer limits storage, so it isn't
    /// offered. MDK still rejects a policy whose value is below the transfer limit.
    static func applying(diskReserve: UInt64, transferLimit: UInt64,
                         to policy: AttachmentDownloadPolicyFfi) -> AttachmentDownloadPolicyFfi {
        var next = policy
        next.diskReserve = diskReserve
        next.transferLimit = transferLimit
        next.retainedBytes = max(policy.retainedBytes, transferLimit)
        return next
    }
}

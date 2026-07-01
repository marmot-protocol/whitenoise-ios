import SwiftUI
import MarmotKit

/// Member collection UI shared by New Chat and Add Members: staged member
/// rows, the reference input with auto-stage / return / "+" affordances, the QR
/// scan entry point, and the validation error. Backed by one
/// `MemberPickerViewModel` owned by the embedding sheet.
struct MemberPickerView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: MemberPickerViewModel
    let title: LocalizedStringKey
    let normalize: MemberPickerViewModel.Normalize
    var scanInvalidMessage: String?

    var body: some View {
        Section(title) {
            ForEach(model.members, id: \.accountIdHex) { member in
                HStack(spacing: 8) {
                    StagedGroupMemberRow(member: member)

                    Button(role: .destructive) {
                        model.remove(member)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("npub1…, nprofile1…, or hex public key", text: $model.pending)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: model.pending) {
                        Task { await model.autoStagePendingIfComplete(normalize: normalize, warmProfile: warmProfile) }
                    }
                    .onSubmit {
                        Task { await model.addPending(normalize: normalize, warmProfile: warmProfile) }
                    }
                Button {
                    Task { await model.addPending(normalize: normalize, warmProfile: warmProfile) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.tint)
                }
                .disabled(model.pending.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button {
                model.error = nil
                model.showScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
        }
        .fullScreenCover(isPresented: $model.showScanner) {
            ScannerSheet { result in
                model.showScanner = false
                Task {
                    await model.addScanned(
                        result,
                        invalidMessage: scanInvalidMessage,
                        normalize: normalize,
                        warmProfile: warmProfile
                    )
                }
            }
            .appAppearance()
        }

        if let error = model.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var warmProfile: MemberPickerViewModel.ProfileWarmup {
        { _ = appState.profile(forAccountIdHex: $0) }
    }
}

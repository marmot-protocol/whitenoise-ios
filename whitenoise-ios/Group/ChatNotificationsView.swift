import SwiftUI

struct ChatNotificationsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: GroupDetailsViewModel

    private var muteStateKey: String {
        "\(appState.activeAccountRef ?? ""):\(appState.runtimeGeneration):\(appState.canUseRuntimeForLocalForegroundWork)"
    }

    var body: some View {
        Form {
            if let error = model.notifyModeError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await model.loadMuteState(using: appState) }
                    }
                    .disabled(model.isUpdatingNotifyMode)
                }
            }
            Section {
                Picker(selection: Binding(
                    get: { model.notifyMode },
                    set: { mode in Task { await model.setNotifyMode(mode, using: appState) } }
                )) {
                    Text("All messages").tag(ChatNotifyMode.all)
                    Text("Only mentions").tag(ChatNotifyMode.mentionsOnly)
                    Text("Nothing").tag(ChatNotifyMode.nothing)
                } label: {
                    Text("Notify me about")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!model.isMuteStateLoaded || model.isUpdatingNotifyMode)
            } footer: {
                Text("Applies on this device only. Messages still arrive and count as unread. With \"Only mentions\", this chat notifies only when someone mentions you.")
            }
        }
        .navigationTitle("Notifications")
        .task(id: muteStateKey) { await model.loadMuteState(using: appState) }
        .task(id: model.muteExpiresAt) {
            guard let deadline = model.muteExpiresAt else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                try Task.checkCancellation()
                await model.loadMuteState(using: appState)
            } catch { }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}

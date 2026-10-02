import SwiftUI

struct ChatNotificationsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: GroupDetailsViewModel

    private var muteStateKey: String {
        "\(appState.activeAccountRef ?? ""):\(appState.isAppSceneActive)"
    }

    var body: some View {
        Form {
            if let error = model.notifyModeError {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        model.loadMuteState(using: appState)
                    }
                }
            }
            Section {
                Picker(selection: Binding(
                    get: { model.notifyMode },
                    set: { mode in model.setNotifyMode(mode, using: appState) }
                )) {
                    Text("All messages").tag(ChatNotifyMode.all)
                    Text("Only mentions").tag(ChatNotifyMode.mentionsOnly)
                    Text("Nothing").tag(ChatNotifyMode.nothing)
                } label: {
                    Text("Notify me about")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!model.isMuteStateLoaded)
            } footer: {
                Text(MutedChatMentionsCopy.chatNotificationsFooter(
                    mentionsBreakThroughMute: model.mentionsBreakThroughMute
                ))
            }
        }
        .navigationTitle("Notifications")
        .task(id: muteStateKey) { model.loadMuteState(using: appState) }
        .task(id: model.muteExpiresAt) {
            guard let deadline = model.muteExpiresAt else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                try Task.checkCancellation()
                model.loadMuteState(using: appState)
            } catch { }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}

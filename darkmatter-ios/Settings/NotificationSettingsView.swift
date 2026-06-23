import SwiftUI
import UserNotifications
import MarmotKit

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = NotificationSettingsViewModel()

    var body: some View {
        Form {
            Section {
                Toggle("Local notifications", isOn: Binding(
                    get: { model.settings?.localNotificationsEnabled ?? false },
                    set: { enabled in Task { await model.setLocalNotifications(enabled, using: appState) } }
                ))
                .disabled(model.isSaving || model.settings == nil)

                Toggle("Native push", isOn: Binding(
                    get: { model.settings?.nativePushEnabled ?? false },
                    set: { enabled in Task { await model.setNativePush(enabled, using: appState) } }
                ))
                .disabled(model.nativePushToggleDisabled)

                if model.isSaving {
                    ProgressView("Saving")
                }

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if let savedAt = model.savedAt {
                    Label(
                        L10n.formatted("Saved %@", savedAt.formatted(.relative(presentation: .named))),
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.callout)
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text(deliveryFooter)
            }

            Section("Status") {
                LabeledContent("Permission") {
                    Text(model.authorizationStatus.displayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("APNS token") {
                    Text(appState.notifications.apnsTokenHex == nil ? L10n.string("Not received") : L10n.string("Received"))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Push server") {
                    Text(NativePushServerConfig.current() == nil ? L10n.string("Not configured") : L10n.string("Configured"))
                        .foregroundStyle(.secondary)
                }

                if let registration = model.registration {
                    LabeledContent("Token fingerprint") {
                        Text(registration.tokenFingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if let lastRegistrationError = appState.notifications.lastRegistrationError {
                    Label(lastRegistrationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if appState.notifications.apnsTokenHex == nil {
                    Button {
                        Task { await model.requestApnsToken(using: appState) }
                    } label: {
                        Label("Request APNS Token", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(model.isSaving)
                } else {
                    Button {
                        Task { await model.refreshApnsToken(using: appState) }
                    } label: {
                        Label("Refresh APNS Token", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(!model.canRefreshApnsToken)

                    Button {
                        Task { await model.syncNativeRegistration(using: appState) }
                    } label: {
                        Label("Sync Native Registration", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canSyncNativeRegistration)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
    }

    // Reads `appState.notifications`, so stays on the view (the toggle/refresh
    // gates that don't touch appState live on the model).
    private var canSyncNativeRegistration: Bool {
        guard !model.isSaving,
              let settings = model.settings,
              settings.nativePushEnabled,
              appState.notifications.apnsTokenHex != nil,
              NativePushServerConfig.current() != nil
        else { return false }
        return true
    }

    private var deliveryFooter: String {
        if NativePushServerConfig.current() == nil {
            return L10n.string("Native push is unavailable in this build until a Darkmatter push server public key is configured.")
        }
        return L10n.string("Native push registers only an encrypted APNS token with Darkmatter. Apple receives generic notification wakes.")
    }
}

private extension UNAuthorizationStatus {
    var displayName: String {
        switch self {
        case .notDetermined:
            return L10n.string("Not requested")
        case .denied:
            return L10n.string("Denied")
        case .authorized:
            return L10n.string("Authorized")
        case .provisional:
            return L10n.string("Provisional")
        case .ephemeral:
            return L10n.string("Ephemeral")
        @unknown default:
            return L10n.string("Unknown")
        }
    }
}

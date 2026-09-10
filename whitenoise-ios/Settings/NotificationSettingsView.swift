import SwiftUI
import UserNotifications
import MarmotKit
import UIKit

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = NotificationSettingsViewModel()

    var body: some View {
        Form {
            permissionSection

            Section {
                Toggle("Local Notifications", isOn: Binding(
                    get: { model.settings?.localNotificationsEnabled ?? false },
                    set: { enabled in Task { await model.setLocalNotifications(enabled, using: appState) } }
                ))
                .disabled(model.isSaving || model.settings == nil)
                .wnNeutralToggleTint()
            } footer: {
                Text("Creates message notifications on this iPhone. Without Native Push, delivery may wait until White Noise is active.")
            }

            Section {
                Toggle("Native Push", isOn: Binding(
                    get: { model.settings?.nativePushEnabled ?? false },
                    set: { enabled in Task { await model.setNativePush(enabled, using: appState) } }
                ))
                .disabled(model.nativePushToggleDisabled)
                .wnNeutralToggleTint()
            } footer: {
                Text("Uses a generic wake-up signal to check for new messages in the background. Message details stay on this iPhone.")
            }

            NotificationPreviewSection(
                mode: model.previewMode,
                isEnabled: previewControlsEnabled,
                setMode: { model.setPreviewMode($0) }
            )

            statusSection

            if appState.developerMode {
                Section("Developer") {
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
        }
        .tint(WNButton.Metrics.accent(for: colorScheme))
        .localizedNavigationTitle("Notifications")
        .productScreen(.settings, section: .notifications)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isSaving {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
    }

    @ViewBuilder
    private var statusSection: some View {
        if model.settings != nil && notificationSetupNeedsAttention {
            Section("Status") {
                statusRows

                Button {
                    Task { await checkNotificationSetup() }
                } label: {
                    Label("Try Again", systemImage: "checkmark.shield")
                }
                .disabled(model.isSaving)
            }
        } else {
            Section("Status") {
                statusRows
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent("Permission") {
            Text(model.authorizationStatus.displayName)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Notifications") {
            Label(
                notificationStatusText,
                systemImage: notificationStatusIcon
            )
            .foregroundStyle(notificationStatusColor)
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        switch model.authorizationStatus {
        case .notDetermined:
            Section {
                Label("Allow notifications to use these options.", systemImage: "bell.badge")
                Button("Allow Notifications") {
                    Task { await model.setLocalNotifications(true, using: appState) }
                }
                .disabled(model.isSaving)
            }
        case .denied:
            Section {
                Label {
                    VStack(alignment: .leading) {
                        Text("Notifications are off")
                            .foregroundStyle(.primary)
                        Text("Turn them on in iOS Settings to use these options.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private var notificationSetupNeedsAttention: Bool {
        guard let settings = model.settings else { return true }
        let authorizationGranted: Bool
        switch model.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationGranted = true
        case .denied, .notDetermined:
            authorizationGranted = false
        @unknown default:
            authorizationGranted = false
        }

        if settings.localNotificationsEnabled && !authorizationGranted {
            return true
        }
        if settings.nativePushEnabled {
            return NativePushServerConfig.current() == nil
                || appState.notifications.apnsTokenHex == nil
                || model.registration == nil
        }
        return false
    }

    /// The preview choice only governs notifications this device renders, so
    /// it stays inert until local notifications can actually be delivered.
    private var previewControlsEnabled: Bool {
        guard let settings = model.settings, settings.localNotificationsEnabled else { return false }
        switch model.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private var notificationsEnabled: Bool {
        guard let settings = model.settings else { return false }
        return settings.localNotificationsEnabled || settings.nativePushEnabled
    }

    private var notificationStatusText: String {
        guard model.settings != nil else {
            return L10n.string("Loading push notification state…")
        }
        if !notificationsEnabled {
            return L10n.string("Off")
        }
        return notificationSetupNeedsAttention
            ? L10n.string("Notifications unavailable")
            : L10n.string("Configured")
    }

    private var notificationStatusIcon: String {
        guard model.settings != nil else {
            return "clock"
        }
        if !notificationsEnabled {
            return "bell.slash.fill"
        }
        return notificationSetupNeedsAttention
            ? "exclamationmark.triangle.fill"
            : "checkmark"
    }

    private var notificationStatusColor: Color {
        guard model.settings != nil else {
            return .secondary
        }
        if !notificationsEnabled {
            return .secondary
        }
        return notificationSetupNeedsAttention ? .orange : .primary
    }

    private func checkNotificationSetup() async {
        guard let settings = model.settings else {
            await model.reload(using: appState)
            return
        }
        if settings.localNotificationsEnabled && !model.canRefreshApnsToken {
            await model.requestApnsToken(using: appState)
        } else if settings.nativePushEnabled && appState.notifications.apnsTokenHex == nil {
            await model.requestApnsToken(using: appState)
        } else if settings.nativePushEnabled {
            await model.syncNativeRegistration(using: appState)
        } else {
            await model.reload(using: appState)
        }
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

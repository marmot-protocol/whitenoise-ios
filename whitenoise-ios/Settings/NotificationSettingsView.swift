import SwiftUI
import UserNotifications
import MarmotKit
import UIKit

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = NotificationSettingsViewModel()
    @State private var progressAction: NotificationSettingsViewModel.Action?

    var body: some View {
        Form {
            loadingSection

            permissionSection

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    notificationToggle(
                        "Local Notifications",
                        action: .localNotifications,
                        unavailable: model.settings == nil,
                        isOn: Binding(
                            get: { model.settings?.localNotificationsEnabled ?? false },
                            set: { enabled in Task { await model.setLocalNotifications(enabled, using: appState) } }
                        )
                    )
                    Text("Shows message notifications on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    actionFeedback(.localNotifications)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    notificationToggle(
                        "Native Push",
                        action: .nativePush,
                        unavailable: model.nativePushToggleUnavailable,
                        isOn: Binding(
                            get: { model.settings?.nativePushEnabled ?? false },
                            set: { enabled in Task { await model.setNativePush(enabled, using: appState) } }
                        )
                    )
                    Text("Helps notifications arrive when White Noise is closed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    actionFeedback(.nativePush)

                    if !model.isLoading && nativePushNeedsAttention {
                        Label("Native Push setup is incomplete.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        WNGrayButton(title: L10n.string("Try Again"), isLoading: showsProgress(for: .setup)) {
                            Task { await checkNotificationSetup() }
                        }
                        .disabled(model.isSaving)
                    }
                    actionFeedback(.setup)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Current Profile").wnSectionHeader()
            }

            Section {
                NotificationPreviewRows(
                    mode: model.previewMode,
                    isEnabled: previewControlsEnabled,
                    setMode: {
                        model.setPreviewMode($0)
                        appState.notifications.cancelForegroundBatches()
                    }
                )
            } header: {
                Text("All Profiles on This Device").wnSectionHeader()
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    WNToggle("Mentions in Muted Chats", isOn: Binding(
                        get: { model.mentionsBreakThroughMute },
                        set: { model.setMentionsBreakThroughMute($0) }
                    ))
                    Text("Notify me when I’m mentioned in a muted chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .disabled(!previewControlsEnabled)
            }

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
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
        .onChange(of: nativePushSetupComplete) { _, isComplete in
            if isComplete { model.clearResolvedSetupError() }
        }
        .task(id: model.activeAction) {
            progressAction = nil
            guard let action = model.activeAction else { return }
            // Delay presentation only: the existing action and duplicate-submission gate run immediately.
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled, model.activeAction == action else { return }
            progressAction = action
        }
    }

    @ViewBuilder
    private var loadingSection: some View {
        if model.isLoading {
            Section {
                ProgressView("Loading…")
            }
        } else if model.settings == nil {
            Section {
                Text("Couldn't load notification settings")
                    .font(.callout)
                WNGrayButton(title: L10n.string("Retry")) {
                    Task { await model.reload(using: appState) }
                }
                .disabled(model.isSaving)
            }
        }
    }

    private func showsProgress(for action: NotificationSettingsViewModel.Action) -> Bool {
        model.activeAction == action && progressAction == action
    }

    private func notificationToggle(
        _ title: LocalizedStringKey,
        action: NotificationSettingsViewModel.Action,
        unavailable: Bool,
        isOn: Binding<Bool>
    ) -> some View {
        WNToggle(isOn: isOn) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
                    .opacity(showsProgress(for: action) ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(showsProgress(for: action) ? Text("Saving…") : Text(""))
        // Block taps immediately, but avoid a disabled-color flash for a fast save.
        // The model's existing action gate also rejects overlapping actions.
        .allowsHitTesting(!model.isSaving)
        .disabled(unavailable || (model.activeAction != nil && progressAction == model.activeAction))
    }

    @ViewBuilder
    private func actionFeedback(_ action: NotificationSettingsViewModel.Action) -> some View {
        if let error = model.actionErrors[action] {
            Label {
                Text(error)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        if model.hasLoadedAuthorization {
            permissionContent
        }
    }

    @ViewBuilder
    private var permissionContent: some View {
        switch model.authorizationStatus {
        case .notDetermined:
            Section {
                Label("Allow notifications to use these options.", systemImage: "bell.badge")
                WNGrayButton(title: L10n.string("Allow Notifications")) {
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
                WNGrayButton(title: L10n.string("Open Settings")) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private var nativePushNeedsAttention: Bool {
        guard let settings = model.settings, settings.nativePushEnabled else { return false }
        return NativePushServerConfig.current() == nil
            || appState.notifications.apnsTokenHex == nil
            || model.registration == nil
    }

    private var nativePushSetupComplete: Bool {
        !model.isLoading && model.settings?.nativePushEnabled == true && !nativePushNeedsAttention
    }

    /// The preview and muted-mention choices only govern notifications this
    /// device renders, so they stay inert until local notifications can
    /// actually be delivered.
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

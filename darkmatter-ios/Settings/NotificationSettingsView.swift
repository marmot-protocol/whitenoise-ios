import SwiftUI
import UserNotifications
import MarmotKit

struct NotificationSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var settings: NotificationSettingsFfi?
    @State private var registration: PushRegistrationFfi?
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedAt: Date?

    var body: some View {
        Form {
            Section {
                Toggle("Local notifications", isOn: Binding(
                    get: { settings?.localNotificationsEnabled ?? false },
                    set: { enabled in Task { await setLocalNotifications(enabled) } }
                ))
                .disabled(isSaving || settings == nil)

                Toggle("Native push", isOn: Binding(
                    get: { settings?.nativePushEnabled ?? false },
                    set: { enabled in Task { await setNativePush(enabled) } }
                ))
                .disabled(nativePushToggleDisabled)

                if isSaving {
                    ProgressView("Saving")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                if let savedAt {
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
                    Text(authorizationStatus.displayName)
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

                if let registration {
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
                        Task { await requestApnsToken() }
                    } label: {
                        Label("Request APNS Token", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(isSaving)
                } else {
                    Button {
                        Task { await refreshApnsToken() }
                    } label: {
                        Label("Refresh APNS Token", systemImage: "arrow.clockwise.circle")
                    }
                    .disabled(!canRefreshApnsToken)

                    Button {
                        Task { await syncNativeRegistration() }
                    } label: {
                        Label("Sync Native Registration", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!canSyncNativeRegistration)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccountRef) { await reload() }
        .refreshable { await reload() }
    }

    private var nativePushToggleDisabled: Bool {
        guard !isSaving, let settings else { return true }
        if settings.nativePushEnabled {
            return false
        }
        return NativePushServerConfig.current() == nil
    }

    private var canRefreshApnsToken: Bool {
        guard !isSaving else { return false }
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private var canSyncNativeRegistration: Bool {
        guard !isSaving,
              let settings,
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

    @MainActor
    private func reload() async {
        authorizationStatus = await appState.notifications.authorizationStatus()
        guard let accountRef = appState.activeAccountRef else {
            settings = nil
            registration = nil
            return
        }
        settings = await appState.notificationSettings(for: accountRef)
        registration = await appState.pushRegistration(for: accountRef)
    }

    @MainActor
    private func setLocalNotifications(_ enabled: Bool) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            settings = try await appState.setLocalNotificationsEnabled(enabled)
            savedAt = Date()
            Haptics.success()
            await reload()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func setNativePush(_ enabled: Bool) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            settings = try await appState.setNativePushEnabled(enabled)
            savedAt = Date()
            Haptics.success()
            await reload()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func requestApnsToken() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let granted = try await appState.notifications.requestAuthorizationAndRegister()
            guard granted else { throw NotificationSettingsActionError.permissionDenied }
            savedAt = Date()
            await reload()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshApnsToken() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await appState.notifications.refreshApnsToken()
            savedAt = Date()
            Haptics.success()
            await reload()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    @MainActor
    private func syncNativeRegistration() async {
        guard let accountRef = appState.activeAccountRef else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            registration = try await appState.syncNativePushRegistration(accountRef: accountRef)
            savedAt = Date()
            Haptics.success()
            await reload()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
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

import MarmotKit
import SwiftUI

/// Settings → Devices: this profile's linked devices, link requests waiting
/// here, sign-ins this device doesn't recognize, and device-group repair.
struct LinkedDevicesView: View {
    private enum Confirmation: Identifiable {
        case reject(UnrecognizedSignInFfi)
        case startFresh
        case reset

        var id: String {
            switch self {
            case .reject(let signIn): "reject:\(signIn.slotIdHex)"
            case .startFresh: "startFresh"
            case .reset: "reset"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @State private var busyKey: String?
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?

    private var store: DeviceLinkStore { appState.deviceLinks }

    var body: some View {
        Form {
            if !store.compromiseWarning.isEmpty { compromiseSection }
            if store.deviceGroupStalled { stalledSection }
            if !store.pendingPrompts.isEmpty { requestsSection }
            let otherRequests = store.otherProfileRequests(using: appState)
            if !otherRequests.isEmpty { otherProfilesSection(otherRequests) }
            devicesSections
            linkSection
            if !store.moves.isEmpty { movesSection }
            signInsSection
            if store.keyPackageRefreshOverdue { keyPackageSection }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .localizedNavigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh(using: appState) }
        .task(id: "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)") {
            await store.refresh(using: appState)
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            presenting: confirmation
        ) { item in
            switch item {
            case .reject(let signIn):
                Button("This Wasn’t Me", role: .destructive) {
                    run("signIn:\(signIn.slotIdHex)") {
                        try await store.answerSignIn(slotIdHex: signIn.slotIdHex, response: .reject, using: appState)
                    }
                }
            case .startFresh:
                Button("Start Fresh") { run("startFresh") { try await store.startFresh(using: appState) } }
            case .reset:
                Button("Reset", role: .destructive) {
                    run("reset") {
                        try await store.resetForRepair(using: appState)
                        store.present(.linkThisDevice)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            switch item {
            case .reject:
                Text("Your devices will refuse to link this sign-in and will warn you about it. Use this only if you didn’t sign in there.")
            case .startFresh:
                Text("Your earlier sign-ins won’t be asked about again, and only chats you’re invited to from now on appear here. You can still link this device to one of them later.")
            case .reset:
                Text("This device forgets its list of your other devices and publishes a new messaging key so it can be linked again. Your chats, messages and private key stay on this device.")
            }
        }
    }

    private var confirmationTitle: LocalizedStringKey {
        switch confirmation {
        case .reject: "Mark Sign-In as Not You?"
        case .startFresh: "Start Fresh on This Device?"
        case .reset: "Reset This Device’s Links?"
        case nil: ""
        }
    }

    // MARK: - Sections

    private var compromiseSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Someone else may have your private key", systemImage: "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Someone published from your profile where your devices didn’t. Anyone with your private key can read and send messages as you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(store.compromiseWarning.enumerated()), id: \.offset) { _, item in
                    Text(CompromiseWarningPresentation.detail(item))
                        .font(.footnote)
                }
            }
            .padding(.vertical, 4)
            Button("Dismiss") {
                run("compromise") { try await store.dismissCompromiseWarning(using: appState) }
            }
            .disabled(busyKey != nil)
        }
    }

    private var stalledSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("This Device Is Out of Sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("This device can no longer catch up with your other devices. Reset its links, then link it to another device again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Reset and Link Again") { confirmation = .reset }
                .disabled(busyKey != nil)
        }
    }

    private var requestsSection: some View {
        Section("Link Requests") {
            ForEach(store.pendingPrompts, id: \.promptId) { prompt in
                Button {
                    store.present(.approve(promptID: prompt.promptId))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("A device wants to link")
                                .foregroundStyle(.primary)
                            Text(DeviceLinkPromptPresentation.summary(prompt.state))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func otherProfilesSection(_ requests: [OtherProfileLinkRequest]) -> some View {
        Section {
            ForEach(requests) { request in
                HStack {
                    Text(L10n.formatted(
                        "A device wants to link %@.", appState.displayName(forAccountIdHex: request.accountIdHex)
                    ))
                    Spacer()
                    Button("Review") {
                        Task { await store.reviewOtherProfileRequest(request, using: appState) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Other Profiles")
        } footer: {
            Text("Review switches to that profile to compare the emoji.")
        }
    }

    @ViewBuilder
    private var devicesSections: some View {
        if let loadError = store.devicesLoadError {
            Section {
                Text(loadError).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.refresh(using: appState) } }
            }
        } else if store.hasDeviceGroup {
            if let thisDevice = store.thisDevice {
                Section("This Device") { deviceRow(thisDevice) }
            }
            Section {
                if store.otherDevices.isEmpty {
                    Text("No other devices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.otherDevices, id: \.slotIdHex) { deviceRow($0) }
                }
            } header: {
                Text("Your Other Devices")
            } footer: {
                let lines = LinkedDevicePresentation.chatCounts(
                    closedToLinkedDevices: store.chatsClosedToLinkedDevices, leftoverChats: store.leftoverChats
                )
                if !lines.isEmpty {
                    Text(lines.joined(separator: "\n"))
                }
            }
        } else {
            Section {
                Label("This device isn’t linked to any other devices.", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            } footer: {
                if store.startedFresh {
                    Text("This device started fresh. Only chats you’re invited to from now on appear here.")
                }
            }
        }
    }

    private func deviceRow(_ device: LinkedDeviceFfi) -> some View {
        NavigationLink {
            LinkedDeviceDetailView(slotIdHex: device.slotIdHex)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: LinkedDevicePresentation.symbol(device))
                    .font(.title3)
                    .frame(width: 32)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LinkedDevicePresentation.name(device))
                    let details = [LinkedDevicePresentation.detailClientLine(device), LinkedDevicePresentation.lastActive(device)]
                        .compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let status = LinkedDevicePresentation.status(device) {
                        Text(status)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    if let progress = LinkedDevicePresentation.chatProgress(device, progress: store.chatProgress) {
                        Text(progress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var linkSection: some View {
        Section {
            // This device already has the chats: the new device asks, and the request appears here.
            Button {
                store.present(.addDevice)
            } label: {
                Label("Add a New Device", systemImage: "plus.circle")
            }
            if store.newDeviceStep.isInProgress {
                Button {
                    store.present(.linkThisDevice)
                } label: {
                    Label("Linking in progress…", systemImage: "hourglass")
                }
            } else {
                // This is the new device, or one moving to another list: ask a device there to approve it.
                Button {
                    store.present(.linkThisDevice)
                } label: {
                    Label("Link to Another Device", systemImage: "link")
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Use Add a New Device on a device that already has your chats. Use Link to Another Device on the new device, to bring your chats to it.")
                if store.hasDeviceGroup, !store.deviceGroupStalled {
                    Text("This device is already linked to other devices. Linking it to another device moves it to that device’s list.")
                }
                if store.warnsAboutPendingLinkBeforeMove {
                    Text("Finish linking your new device before moving this device. Moving now can stop it from joining your chats.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var movesSection: some View {
        Section("Moving This Device") {
            ForEach(store.moves, id: \.moveId) { move in
                Text(DeviceGroupMovePresentation.title(move.state))
                ForEach(DeviceGroupMovePresentation.siblings(move), id: \.slotIdHex) { sibling in
                    let key = "moveSibling:\(move.moveId):\(sibling.slotIdHex)"
                    HStack {
                        Text(DeviceGroupMovePresentation.siblingMessage(sibling))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") {
                            run(key) {
                                try await store.dismissMoveSibling(
                                    moveId: move.moveId, slotIdHex: sibling.slotIdHex, using: appState
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(busyKey != nil)
                    }
                }
            }
        }
    }

    private var signInsSection: some View {
        Section {
            if let error = store.signInsLoadError, store.signIns.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if store.signIns.isEmpty {
                Text("No sign-ins to review.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.signIns, id: \.slotIdHex) { signIn in
                signInRow(signIn)
            }
            if UnrecognizedSignInPresentation.offersStartFresh(
                signIns: store.signIns, hasDeviceGroup: store.hasDeviceGroup, startedFresh: store.startedFresh
            ) {
                Button("No, Start Fresh") { confirmation = .startFresh }
                    .disabled(busyKey != nil)
            }
            Button {
                run("check") { try await store.checkSignIns(using: appState) }
            } label: {
                HStack {
                    Label("Check Now", systemImage: "arrow.clockwise")
                    if busyKey == "check" {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(busyKey != nil)
        } header: {
            Text("Sign-Ins to Review")
        } footer: {
            Text("Sign-ins this device doesn’t recognize. To link one that’s yours, tap it and follow the steps on that device; mark one you don’t recognize as not you.")
        }
    }

    private func signInRow(_ signIn: UnrecognizedSignInFfi) -> some View {
        HStack(alignment: .top) {
            if UnrecognizedSignInPresentation.answeredElsewhere(signIn) {
                signInSummary(signIn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // MDK links only from the new device's side, so a tap explains how and waits for its request.
                Button {
                    store.present(.addDevice)
                } label: {
                    signInSummary(signIn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Menu {
                if UnrecognizedSignInPresentation.answeredElsewhere(signIn) {
                    Button("Dismiss") { answer(signIn, .dismiss) }
                } else {
                    Button("Link This Device…") { store.present(.addDevice) }
                    if signIn.state == .prompt {
                        Button("Not Now") { answer(signIn, .notNow) }
                    }
                    Button("This Wasn’t Me", role: .destructive) { confirmation = .reject(signIn) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("Actions"))
            .disabled(busyKey != nil)
        }
    }

    private func signInSummary(_ signIn: UnrecognizedSignInFfi) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(UnrecognizedSignInPresentation.title(signIn))
            Text(UnrecognizedSignInPresentation.detail(signIn))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if signIn.previouslyLinkedHere {
                Text("A device previously linked here is missing from this device’s list. Open both devices to check the link.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var keyPackageSection: some View {
        Section {
            Label {
                Text("This device couldn’t refresh its messaging key for over a week, so people may soon be unable to add it to new chats. Keep White Noise open and online so your devices can sync.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    private func answer(_ signIn: UnrecognizedSignInFfi, _ response: SignInResponseFfi) {
        run("signIn:\(signIn.slotIdHex)") {
            try await store.answerSignIn(slotIdHex: signIn.slotIdHex, response: response, using: appState)
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

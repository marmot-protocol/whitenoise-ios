import SwiftUI
import MarmotKit

/// One navigation row on the profile; the full group list lives one level down.
struct GroupsInCommonRow: View {
    private let groups: [SharedGroupsProjection.SharedGroup]
    let hasLoaded: Bool
    let loadError: String?
    let onRetry: () -> Void
    let onOpenChat: (String) -> Void
    var onAddToGroup: () -> Void

    init(
        sharedGroups: [SharedGroupsProjection.SharedGroup],
        hasLoaded: Bool,
        loadError: String?,
        onRetry: @escaping () -> Void,
        onOpenChat: @escaping (String) -> Void,
        onAddToGroup: @escaping () -> Void
    ) {
        groups = sharedGroups.filter { !$0.isDirectMessage }
        self.hasLoaded = hasLoaded
        self.loadError = loadError
        self.onRetry = onRetry
        self.onOpenChat = onOpenChat
        self.onAddToGroup = onAddToGroup
    }

    var body: some View {
        if !hasLoaded {
            if loadError != nil {
                Button(action: onRetry) {
                    Label("Couldn't load groups", systemImage: "arrow.clockwise")
                }
                .accessibilityHint("Retry")
            } else {
                HStack {
                    Label("Groups in Common", systemImage: "person.2")
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            }
        } else if groups.isEmpty {
            Button("Add to Group", systemImage: "person.2.badge.plus", action: onAddToGroup)
        } else {
            NavigationLink {
                GroupsInCommonView(
                    groups: groups,
                    onOpenChat: onOpenChat,
                    onAddToGroup: onAddToGroup
                )
            } label: {
                HStack {
                    HStack(spacing: -10) {
                        ForEach(groups.prefix(3)) { group in
                            GroupAvatarBubble(
                                groupIdHex: group.groupIdHex,
                                imageHashHex: group.imageHashHex,
                                seed: group.groupIdHex,
                                title: group.title,
                                pictureURL: ContentSanitizer.imageURL(group.avatarUrl)
                            )
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: .systemGray5), in: Circle())
                            .overlay { Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2) }
                        }
                        if groups.count > 3 {
                            Text("+\(groups.count - 3)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .frame(width: 32, height: 32)
                                .background(Color(uiColor: .systemGray5), in: Circle())
                                .overlay { Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2) }
                        }
                    }
                    .accessibilityHidden(true)
                    Text("Groups in Common")
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(L10n.plural("%lld groups in common", Int64(groups.count)))
            }
        }
    }
}

private struct GroupsInCommonView: View {
    let groups: [SharedGroupsProjection.SharedGroup]
    let onOpenChat: (String) -> Void
    let onAddToGroup: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(groups) { group in
                    Button {
                        onOpenChat(group.groupIdHex)
                    } label: {
                        HStack {
                            ProfileGroupSummaryRow(group: group)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Button("Add to Another Group", systemImage: "person.2.badge.plus", action: onAddToGroup)
            }
        }
        .navigationTitle("Groups in Common")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileGroupSummaryRow: View {
    let group: SharedGroupsProjection.SharedGroup

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatarBubble(
                groupIdHex: group.groupIdHex,
                imageHashHex: group.imageHashHex,
                seed: group.groupIdHex,
                title: group.title,
                pictureURL: ContentSanitizer.imageURL(group.avatarUrl)
            )
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(L10n.plural("%lld members", Int64(group.memberCount)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }
}

/// Picker over the groups the viewer administers that don't yet include the
/// contact. Selecting one publishes the invite; the engine enforces admin
/// rights on the mutation path.
struct AddToGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let contactNpub: String
    let contactName: String
    let groups: [SharedGroupsProjection.SharedGroup]
    var isLoading = false
    var loadError: String?
    var onRetry: () -> Void = {}
    var onAdded: @MainActor () async -> Void = {}

    @State private var busyGroupIdHex: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(groups) { group in
                        Button {
                            Task { await add(to: group) }
                        } label: {
                            HStack {
                                ProfileGroupSummaryRow(group: group)
                                if busyGroupIdHex == group.groupIdHex {
                                    ProgressView()
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(busyGroupIdHex != nil)
                    }
                } footer: {
                    Text(L10n.formatted("Adds %@ to the group you pick.", contactName))
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if groups.isEmpty, error == nil {
                    if isLoading || busyGroupIdHex != nil {
                        ProgressView()
                    } else if let loadError {
                        ContentUnavailableView {
                            Label("Couldn't load groups", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(loadError)
                        } actions: {
                            Button("Retry", action: onRetry)
                        }
                    } else {
                        ContentUnavailableView("No Available Groups", systemImage: "person.3")
                    }
                }
            }
            .navigationTitle("Add to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(busyGroupIdHex != nil)
                }
            }
            .interactiveDismissDisabled(busyGroupIdHex != nil)
        }
    }

    private func add(to group: SharedGroupsProjection.SharedGroup) async {
        guard busyGroupIdHex == nil, let accountRef = appState.activeAccountRef else { return }
        let runtimeGeneration = appState.runtimeGeneration
        busyGroupIdHex = group.groupIdHex
        defer { busyGroupIdHex = nil }
        error = nil
        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.inviteMembersDetailed(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                memberRefs: [contactNpub]
            )
            guard isCurrent(accountRef: accountRef, runtimeGeneration: runtimeGeneration) else { return }
            await onAdded()
            guard isCurrent(accountRef: accountRef, runtimeGeneration: runtimeGeneration) else { return }
            Haptics.success()
            appState.present(.success(L10n.string("Added to group"), message: group.title))
            dismiss()
        } catch let marmotError as MarmotKitError {
            guard isCurrent(accountRef: accountRef, runtimeGeneration: runtimeGeneration) else { return }
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                error = L10n.formatted(
                    "%@ hasn't published a compatible key package yet.",
                    IdentityPresentation.text(accountIdHex: account)
                )
            } else {
                error = UserFacingError.message(for: marmotError)
            }
        } catch {
            guard isCurrent(accountRef: accountRef, runtimeGeneration: runtimeGeneration) else { return }
            Haptics.error()
            self.error = UserFacingError.message(for: error)
        }
    }

    private func isCurrent(accountRef: String, runtimeGeneration: Int) -> Bool {
        !Task.isCancelled
            && appState.activeAccountRef == accountRef
            && appState.runtimeGeneration == runtimeGeneration
    }

}

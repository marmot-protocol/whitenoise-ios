import SwiftUI
import MarmotKit

/// The groups-in-common block shown on a contact's pages: create a group
/// with them, add them to a group you administer, then the groups you share,
/// collapsed to a short preview with See all.
struct GroupsInCommonSection: View {
    let contactAccountIdHex: String
    let contactNpub: String
    let contactName: String
    let sharedGroups: [SharedGroupsProjection.SharedGroup]
    let addableGroups: [SharedGroupsProjection.SharedGroup]
    let onOpenChat: (String) -> Void
    var showsActions = true
    /// Hoisted to the owning screen: sheets attached to a `Section` detach
    /// when the list re-renders (the same hazard as the picker scanner).
    var onStartGroup: () -> Void = {}
    var onAddToGroup: () -> Void = {}

    @State private var expanded = false

    private static let previewCount = 3

    var body: some View {
        Section {
            if showsActions {
                Button {
                    onStartGroup()
                } label: {
                    Label(
                        L10n.formatted("Create group with %@", contactName),
                        systemImage: "plus"
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if !addableGroups.isEmpty {
                    Button {
                        onAddToGroup()
                    } label: {
                        Label("Add to group", systemImage: "person.2.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(visibleShared) { group in
                let displayTitle = group.isDirectMessage
                    ? contactName
                    : group.title
                Button {
                    onOpenChat(group.groupIdHex)
                } label: {
                    HStack(spacing: 12) {
                        GroupAvatarBubble(
                            groupIdHex: group.groupIdHex,
                            imageHashHex: group.imageHashHex,
                            seed: group.groupIdHex,
                            title: displayTitle,
                            pictureURL: ContentSanitizer.imageURL(group.avatarUrl)
                        )
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayTitle)
                                .lineLimit(1)
                            if group.isDirectMessage {
                                HStack(spacing: 3) {
                                    Image(systemName: "person.fill")
                                    Text("Direct message")
                                }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.plural("%lld members", Int64(group.memberCount)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if !expanded, sharedGroups.count > Self.previewCount {
                Button {
                    expanded = true
                } label: {
                    HStack {
                        Text("See all")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text(L10n.plural("%lld groups in common", Int64(sharedGroups.count)))
        }
    }

    private var visibleShared: [SharedGroupsProjection.SharedGroup] {
        expanded ? sharedGroups : Array(sharedGroups.prefix(Self.previewCount))
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
                            HStack(spacing: 12) {
                                GroupAvatarBubble(
                                    groupIdHex: group.groupIdHex,
                                    imageHashHex: group.imageHashHex,
                                    seed: group.groupIdHex,
                                    title: group.title,
                                    pictureURL: ContentSanitizer.imageURL(group.avatarUrl)
                                )
                                .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(group.title)
                                        .lineLimit(1)
                                    Text(L10n.plural("%lld members", Int64(group.memberCount)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
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
            .navigationTitle("Add to group")
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
            await onAdded()
            Haptics.success()
            appState.present(.success(L10n.string("Added to group"), message: group.title))
            dismiss()
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                error = L10n.formatted(
                    "%@ hasn't published a compatible key package yet.",
                    IdentityPresentation.text(accountIdHex: account)
                )
            } else {
                error = marmotError.localizedDescription
            }
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
    }
}

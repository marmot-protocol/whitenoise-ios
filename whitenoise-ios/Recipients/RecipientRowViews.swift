import SwiftUI
import UIKit
import MarmotKit

/// One person in a recipient list: avatar, resolved name, and identity
/// context. Search rows identify whether the user follows the result, while
/// non-search rows stay focused on identity. The trailing slot carries
/// selection or progress state.
struct RecipientRow<Trailing: View>: View {
    @Environment(AppState.self) private var appState
    let accountIdHex: String
    let profileOverride: UserProfileMetadataFfi?
    let searchContext: RecipientSearch.ResultContext?
    let trailing: Trailing

    init(
        accountIdHex: String,
        profileOverride: UserProfileMetadataFfi? = nil,
        searchContext: RecipientSearch.ResultContext? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.accountIdHex = accountIdHex
        self.profileOverride = profileOverride
        self.searchContext = searchContext
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: accountIdHex,
                title: displayName,
                pictureURL: appState.avatarURL(forAccountIdHex: accountIdHex)
                    ?? ContentSanitizer.imageURL(profileOverride?.picture)
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let searchContextLabel {
                    Text(searchContextLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let npub {
                    Text(npub)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var npub: String? {
        IdentityPresentation.subtitleNpub(
            accountIdHex: accountIdHex,
            knownName: knownName
        )
    }

    private var displayName: String {
        IdentityPresentation.text(accountIdHex: accountIdHex, knownName: knownName)
    }

    private var knownName: String? {
        appState.knownDisplayName(forAccountIdHex: accountIdHex)
            ?? AppState.resolvedKnownDisplayName(
                profile: profileOverride,
                projectedName: nil,
                localAccountLabel: nil
            )
    }

    private var searchContextLabel: String? {
        switch searchContext {
        case .youFollow:
            L10n.string("You follow")
        case .searchResult:
            L10n.string("Search result")
        case nil:
            nil
        }
    }
}

struct RecipientUserSearchStatus: View {
    let isSearching: Bool
    let isIncomplete: Bool
    let didFail: Bool
    let onRetry: () -> Void

    var body: some View {
        if isSearching {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching your network…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if didFail {
            Section {
                Label("Search couldn’t be completed.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry", action: onRetry)
            }
        } else if isIncomplete {
            Section {
                Label("Some search results may be missing.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Selection state for multi-select recipient rows: a check on the rows that
/// are in, and nothing on the rows that are not.
struct RecipientSelectionIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    var body: some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(WNButton.Metrics.accent(for: colorScheme))
            // Unselected rows keep the slot rather than drop it, so a name does
            // not reflow the moment the row is tapped.
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Removable horizontal rail of the currently selected people.
struct SelectedRecipientRail: View {
    nonisolated enum Metrics {
        static let avatarSize: CGFloat = 52
        /// `.headline` renders an SF Symbol at roughly this diameter; the inset
        /// below is derived from it rather than eyeballed.
        static let badgeSize: CGFloat = 17
        static let labelWidth: CGFloat = 64

        /// Nudges the badge until its centre sits on the avatar's edge at 45°.
        /// The old inset floated it a few points clear of the circle, off in the
        /// corner of a frame the artwork never reaches.
        static var badgeInset: CGFloat {
            let radius = avatarSize / 2
            return badgeSize / 2 - radius * (1 - 1 / CGFloat(2).squareRoot())
        }

        /// Where the badge's centre lands, in avatar coordinates, for the inset
        /// above.
        static var badgeCentre: CGPoint {
            CGPoint(
                x: avatarSize - badgeSize / 2 + badgeInset,
                y: badgeSize / 2 - badgeInset
            )
        }
    }

    /// The remove badge is the same filled circle as every other WN control:
    /// accent disc, glyph knocked out of it, so it inverts with the appearance
    /// instead of staying a black disc on a dark chip.
    nonisolated enum Palette {
        static func removeFill(for colorScheme: ColorScheme) -> Color {
            WNButton.Metrics.accent(for: colorScheme)
        }

        static func removeGlyph(for colorScheme: ColorScheme) -> Color {
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: colorScheme,
                isEnabled: true
            )
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let members: [MemberRefFfi]
    let onRemove: (MemberRefFfi) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(members, id: \.accountIdHex) { member in
                    railChip(for: member)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .animation(.snappy(duration: 0.2), value: members.map(\.accountIdHex))
    }

    private func railChip(for member: MemberRefFfi) -> some View {
        let name = IdentityPresentation.text(
            accountIdHex: member.accountIdHex,
            knownName: appState.knownDisplayName(forAccountIdHex: member.accountIdHex)
        )
        return Button {
            onRemove(member)
        } label: {
            VStack(spacing: 4) {
                AvatarBubble(
                    seed: member.accountIdHex,
                    title: name,
                    pictureURL: appState.avatarURL(forAccountIdHex: member.accountIdHex)
                )
                .frame(width: Metrics.avatarSize, height: Metrics.avatarSize)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.headline)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            Palette.removeGlyph(for: colorScheme),
                            Palette.removeFill(for: colorScheme)
                        )
                        .offset(x: Metrics.badgeInset, y: -Metrics.badgeInset)
                }
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: Metrics.labelWidth)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Remove %@", name))
    }
}

/// Quick action rows shown above the people list (New Group, Scan QR Code).
struct RecipientQuickActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// Matches the disclosure a `NavigationLink` draws for itself, for an
    /// action row that sits in the same card as one.
    var showsDisclosure = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 0)
                if showsDisclosure {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        // Plain keeps the label at label colour, so an action row reads the
        // same as the navigating row it sits beside.
        .buttonStyle(.plain)
    }
}

/// Search field for recipient screens: magnifier, the query, and a paste
/// affordance while empty (a clear button once text is present). Pasting
/// feeds the same query pipeline as typing.
struct RecipientSearchField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search people or paste a profile"
    /// Optional QR-scan affordance rendered beside the paste icon.
    var onScan: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .clipped()
            if text.isEmpty {
                Button {
                    if let pasted = RecipientPasteboard.profileQuery(
                        from: UIPasteboard.general.string
                    ) {
                        text = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.callout)
                        .foregroundStyle(WNButton.Metrics.accent(for: colorScheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste")
                if let onScan {
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.callout)
                            .foregroundStyle(WNButton.Metrics.accent(for: colorScheme))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan QR Code")
                }
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
    }
}

/// Placeholder row while an identifier query resolves against Marmot or a
/// NIP-05 host.
struct RecipientResolvingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .frame(width: 44, height: 44)
            Text("Resolving…")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

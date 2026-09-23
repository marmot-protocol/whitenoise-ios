import SwiftUI

/// Shared identity layout for public profiles, Chat Info, and Share & Connect.
struct ProfileIdentityHeader<Avatar: View>: View {
    let name: String
    let npub: String?
    var profileName: String?
    var nostrAddress: String?
    var isAddressVerified = false
    var bottomPadding: CGFloat = 14
    var showsIdentityValues = true
    @ViewBuilder let avatar: (CGFloat) -> Avatar

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                avatar(geometry.size.width)
            }
            .aspectRatio(1, contentMode: .fit)
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)
            .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(name)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let profileName {
                    Text(L10n.formatted("Name from profile: %@", profileName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if showsIdentityValues, let nostrAddress {
                    ProfileAddressValue(address: nostrAddress, isVerified: isAddressVerified)
                }
            }

            if showsIdentityValues {
                ProfilePublicKeyValue(npub: npub)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top)
        .padding(.bottom, bottomPadding)
    }
}

struct ProfileIdentityValues: View {
    let npub: String?
    var nostrAddress: String?
    var isAddressVerified = false

    var body: some View {
        VStack(spacing: 8) {
            if let nostrAddress {
                ProfileAddressValue(address: nostrAddress, isVerified: isAddressVerified)
            }
            ProfilePublicKeyValue(npub: npub)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProfilePublicKeyValue: View {
    let npub: String?

    var body: some View {
        if let npub {
            CopyableValueChip(
                display: IdentityFormatter.short(npub, head: 14, tail: 4),
                copyValue: npub,
                valueName: L10n.string("npub")
            )
        }
    }
}

private struct ProfileAddressValue: View {
    let address: String
    let isVerified: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(address.count > 38 ? "\(address.prefix(18))…\(address.suffix(19))" : address)
                .lineLimit(1)
                .truncationMode(.middle)
            if isVerified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .accessibilityLabel("Verified address")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(address)
        .accessibilityValue(isVerified ? Text("Verified address") : Text("Not verified"))
    }
}

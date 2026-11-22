import SwiftUI

/// Marks where imported history gives way to live messages, naming the device
/// it came from by its current name.
struct HistoryImportDivider: View {
    let origin: HistoryImportOrigin

    @Environment(AppState.self) private var appState

    private var deviceName: String? {
        guard case .device(let slotIdHex, _) = origin,
              let device = appState.deviceLinks.device(slotIdHex) else { return nil }
        return LinkedDevicePresentation.name(device)
    }

    var body: some View {
        HStack(spacing: 10) {
            line
            Text(HistoryImportPresentation.dividerText(origin, deviceName: deviceName))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            line
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(height: 1)
            .frame(minWidth: 16)
    }
}

/// Progress while a chat's history is still arriving from another device.
struct HistoryImportArrivingBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

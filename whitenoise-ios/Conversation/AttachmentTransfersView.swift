import SwiftUI
import MarmotKit

@MainActor
@Observable
final class AttachmentPresentationState {
    static let shared = AttachmentPresentationState()
    private(set) var revision = 0

    func invalidate() {
        MessageMediaThumbnailDecoder.clear()
        MessageVideoThumbnailDecoder.clear()
        revision &+= 1
    }
}

struct AttachmentTransfersView: View {
    @Environment(AppState.self) private var appState
    let groupID: String
    let items: [MessageMediaAttachment]
    @State private var statuses: [String: AttachmentTransferStatusFfi] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var refresh = 0

    private var attachments: [MessageMediaAttachment] { Array(items.filter { $0.localTarget != nil }.prefix(64)) }

    var body: some View {
        Section("Downloads") {
            ForEach(attachments) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.fileName).lineLimit(2)
                    if let status = statuses[item.id] {
                        Text(AttachmentTransferPresentation.label(status.state))
                            .font(.caption).foregroundStyle(.secondary)
                        if status.state == .downloading {
                            if let total = status.total, total > 0 {
                                ProgressView(value: min(Double(status.received), Double(total)), total: Double(total))
                                    .id(status.attempt)
                            } else { ProgressView().controlSize(.small) }
                        }
                        HStack {
                            if [.queued, .downloading, .retryScheduled, .paused, .verifyingCiphertext,
                                .decrypting, .verifyingPlaintext].contains(status.state) {
                                Button("Cancel download") { perform(item, control: .cancel) }
                            } else if status.state == .ready {
                                Button("Remove download", role: .destructive) { perform(item, control: .remove) }
                            } else if status.state != .unavailable {
                                Button("Download again") { perform(item, control: .retry) }
                            }
                        }
                        .wnSecondaryButtonStyle()
                        .controlSize(.large)
                        .disabled(busy)
                    } else { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .task(id: "\(appState.activeAccountRef ?? "")/\(appState.runtimeGeneration)/\(refresh)/\(attachments.map(\.id).joined())") {
            statuses = [:]
            let requested = attachments
            guard !requested.isEmpty, let account = appState.activeAccountRef else { return }
            do {
                let client = try appState.currentMarmotClient()
                let subscription = try await client.marmot.subscribeAttachmentTransfers(accountRef: account,
                    groupIdHex: groupID, targets: requested.compactMap(\.localTarget))
                try await withTaskCancellationHandler {
                    defer { subscription.cancel() }
                    while let snapshot = try await subscription.next() {
                        try Task.checkCancellation()
                        guard appState.activeAccountRef == account, appState.client === client else { return }
                        statuses = Dictionary(zip(requested.map(\.id), snapshot.items), uniquingKeysWith: { _, new in new })
                    }
                } onCancel: { subscription.cancel() }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = L10n.string("Couldn't load download status.") } }
        }
    }

    private func perform(_ item: MessageMediaAttachment, control: AttachmentControlFfi) {
        guard !busy, let account = appState.activeAccountRef, let target = item.localTarget else { return }
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false; refresh &+= 1 }
            do {
                let client = try appState.currentMarmotClient()
                let current = try await client.marmot.attachmentTransferSnapshot(accountRef: account,
                    groupIdHex: groupID, targets: [target]).items.first
                let applied: Bool
                if control == .retry {
                    applied = try await client.marmot.downloadAttachmentAgain(accountRef: account,
                        groupIdHex: groupID, target: target) != nil
                } else if let reference = current?.reference {
                    applied = try await client.marmot.controlAttachment(accountRef: account,
                        reference: reference, control: control)
                } else { applied = false }
                guard applied else { throw AttachmentReadError.stale }
                if control == .remove, let reference = item.reference {
                    let removed = await MessageMediaCache.removeCachedData(forPlaintextHashes: [reference.plaintextSha256])
                    AttachmentPresentationState.shared.invalidate()
                    guard removed else { throw AttachmentReadError.unavailable }
                }
            } catch { self.error = L10n.string("Couldn't update this download. Please try again.") }
        }
    }
}

nonisolated enum AttachmentTransferPresentation {
    static func label(_ state: AttachmentTransferStateFfi) -> String {
        switch state {
        case .unavailable: L10n.string("Unavailable")
        case .notRequested: L10n.string("Not downloaded")
        case .queued: L10n.string("Queued")
        case .downloading: L10n.string("Downloading")
        case .verifyingCiphertext, .decrypting, .verifyingPlaintext: L10n.string("Verifying download")
        case .ready: L10n.string("Downloaded")
        case .retryScheduled: L10n.string("Waiting to retry")
        case .failed: L10n.string("Download failed")
        case .cancelled: L10n.string("Cancelled")
        case .paused: L10n.string("Paused")
        case .removed: L10n.string("Download removed")
        case .previouslyAcquiredUnavailable: L10n.string("Download unavailable")
        case .completedUnretained: L10n.string("Download not saved")
        case .retryExhausted: L10n.string("Download retry limit reached")
        case .policyBlocked: L10n.string("Download limit reached")
        }
    }
}

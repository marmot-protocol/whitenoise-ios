import Foundation
import MarmotKit

/// Media access used by the timeline and its existing viewers. The live source
/// retains acquisition, caching and handoff ownership in the current downloader.
@MainActor
protocol ConversationMediaSource: AnyObject {
    func data(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async throws -> Data
    func automaticAttachmentByteCount(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Int?
    func fetchAhead(_ media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Bool
    func openHandoff(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?,
                     control: MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease?
    func stopAndDrain() async
    func resume()
}

extension ConversationMediaDownloader: ConversationMediaSource {}

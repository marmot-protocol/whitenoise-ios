import Foundation
import MarmotKit

/// Sonar sticker packs. MDK owns pack discovery, the account's public
/// installed list (kind 10031) and validation of every downloaded image;
/// `stickerPacks` is a synchronous storage read, so it runs off the main actor.
extension MarmotClient {
    func stickerPacks(accountRef: String, installedOnly: Bool, search: String? = nil,
                      limit: UInt32? = nil) async throws -> [StickerPackFfi] {
        try await Task.detached(priority: .userInitiated) { [marmot] in
            try marmot.stickerPacks(accountRef: accountRef, installedOnly: installedOnly, search: search, limit: limit)
        }.value
    }

    func syncStickerPacks(accountRef: String) async throws -> StickerSyncResultFfi {
        try await marmot.syncStickerPacks(accountRef: accountRef)
    }

    /// Fetches a pack by coordinate, `naddr` or Sonar link into local storage
    /// without installing it.
    func fetchStickerPack(accountRef: String, input: String) async throws -> StickerPackFfi {
        try await marmot.fetchStickerPack(accountRef: accountRef, input: input)
    }

    func installStickerPack(accountRef: String, input: String) async throws -> StickerPackFfi {
        try await marmot.installStickerPack(accountRef: accountRef, input: input)
    }

    func uninstallStickerPack(accountRef: String, input: String) async throws {
        try await marmot.uninstallStickerPack(accountRef: accountRef, input: input)
    }

    /// Downloads and validates one sticker image from its public URL. MDK
    /// keeps no copy, so callers cache the result.
    func fetchStickerAsset(accountRef: String, stickerRef: StickerRefFfi) async throws -> StickerAssetFfi {
        try await marmot.fetchStickerAsset(accountRef: accountRef, stickerRef: stickerRef)
    }

    func sendSticker(accountRef: String, groupIdHex: String, stickerRef: StickerRefFfi) async throws -> SendSummaryFfi {
        try await marmot.sendSticker(accountRef: accountRef, groupIdHex: groupIdHex, stickerRef: stickerRef)
    }
}

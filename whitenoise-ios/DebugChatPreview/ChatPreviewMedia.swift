#if DEBUG
import Foundation
import MarmotKit
import SwiftUI

extension EnvironmentValues {
    @Entry var isChatFixture = false
}

@MainActor
final class ChatPreviewMedia: ConversationMediaSource {
    // These are local copies of the prototype's gallery, clip and trail plan.
    nonisolated private static let files: [String: (mime: String, hash: String, dim: String?)] = [
        "gallery-portrait.jpg": ("image/jpeg", "711521da768a3af666832c2216ef7185a8012cd9df55628baf92432821d29c94", "320x480"),
        "fox.jpg": ("image/jpeg", "69882210a731f38139efe97feff1d7fa30e6e6d9984b1d592686eb7793eb17fb", "480x320"),
        "studio-portrait.jpg": ("image/jpeg", "aa1b5159fd1ebb7b0e497d0b8b85fa0a567c0d980eccf4d17c4f2d974f6b3fe2", "512x512"),
        "ostrich.jpg": ("image/jpeg", "75191bf2e0c6b0c695b854535cd4ddebd46cf30d5fae3e4fc4fd29ebff299103", "512x342"),
        "satoshi.jpg": ("image/jpeg", "1e904f28c56c6cbe10287383960eeee741fd976bb9eeff77e78d56a0633a27af", "320x480"),
        "badger.jpg": ("image/jpeg", "5257451d49b4ef05bbceaaa068585634887855702b00e56901407846d54afa93", "512x342"),
        "outdoor-portrait.jpg": ("image/jpeg", "49c8522edc443adfa9fef57281d07fccf61ae28f4ff05e30ebb831bdfb95daa7", "512x512"),
        "ostrich-panorama.jpg": ("image/jpeg", "db95eff0908d249e53440dacf57b0760e98de11d6e38c52c9f3c32afa9989a5e", "480x112"),
        "tall-backdrop.jpg": ("image/jpeg", "46cd302a58606a2ff90e58ecdbb8f95ae5b0987640c7a3734605ea1da911f03d", "112x480"),
        "small-marmots.jpg": ("image/jpeg", "1e5bac0102454a2dc2744da1d4bc6c099f458059551ddf41cee18e6e54af119b", "96x64"),
        "marmot.jpg": ("image/jpeg", "87705e2403fdb1f76beaf474669161292e10c22d06d9e8723d4bde15e3c117b1", "512x342"),
        "trail-landscape.mp4": ("video/mp4", "31afc9bbe8e6eb18ecbadabf3742a629f209c1dc9e5a589882c4b97745d45850", "320x180"),
        "trail-portrait.mp4": ("video/mp4", "c8451ae250fad5779a9f4cc779f15cee7c76740a8ad66484cca5d07d5f737b94", "180x320"),
        "Project Brief.pdf": ("application/pdf", "7b8a205ffdf9050854c73fb43a47b4d8de974c4f756ead61db7e279b03f54dd0", nil),
        "Read Me.txt": ("text/plain", "9567ffde82fd8bd37f79b50e672a843eadfd1e1e322f3f6fdfecb8a8f1d6e518", nil),
        "Assets.zip": ("application/zip", "47020072e5a246eefb76710a4372183f28e3ee07ee7474d0a93d113a7b2b9832", nil),
        "Review Notes.docx": ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "4dad3b544c7df73371f84b80b7387143cc3ad3ad2abd2dacd5d3f485c0553eeb", nil),
        "Budget.xlsx": ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "ffbad4fb3f8c06912d4ffba97dffc32646b802916f184a9768fce73ae0120498", nil),
        "Avery Stone.vcf": ("text/vcard", "8dae466b5575bd620c7257d68458c55cb649b0a60fecd07677cb55209c60a6ca", nil),
        "voice.mp3": ("audio/mpeg", "e0c3c11726d0d6d2c2dc9434e4f0db48decd8f3b5d74cbd62d4de417aedf034e", nil),
        "voice-7s.m4a": ("audio/mp4", "5cf2250e35c871e5fd02f58e4df526df796756477a6b4d70699980256d6a4b6f", nil),
        "voice-18s.m4a": ("audio/mp4", "373456cac372792e8c52e20a260b28c0b06bb9b75144d1699126e139b7b7ce79", nil),
        "voice-82s.m4a": ("audio/mp4", "8879d6326854cff319cbf1ae0763d474eb77a38ceccb84fdf1031d9532bb5ed4", nil),
        "voice-12s.m4a": ("audio/mp4", "908fcb7bca1c23eebdee3fbd2657343b1d49f0c7f8d522fdd316e3b59214e607", nil),
        "elias.jpg": ("image/jpeg", "96017ad1f003d23781389d66537b3d2a6bd09882cb02e82052c94cfd930b5b6a", "512x512"),
        "nora.jpg": ("image/jpeg", "1e4f9c13576ece416d53a2e6a2d24171ec8b49a4afce69ffb9264e8c6fa96308", "512x512"),
        "marmot-party.gif": ("image/gif", "cca4698688dcd0612a29921852bb207bfc0039e608b2661e6dff3086ba1cc466", "128x128"),
        "morning.wav": ("audio/wav", "5d892c96ee35e2ba20b2af917cdbc46259e2fd88c61066a18a9ea2ae4e3b766e", nil),
        "portrait.jpg": ("image/jpeg", "3d3eb85d0b0f17ae9aefbc27a4e3b7af83d2e83cff7319006ef2f2add922f847", "512x512"),
        "studio.jpg": ("image/jpeg", "7271005be734fcb613da8aa66073d591a8e9019f34f04fb518572e53a1832c3e", "512x512"),
        "portrait-study.jpg": ("image/jpeg", "5585a12662b85839168c8c6dd90c32dc6225603eda91e2ecc938ce6499c2a748", "512x512"),
        "tall-portrait.jpg": ("image/jpeg", "40140812d8817fe6c5f3a7a79872a385a3bab1611def47e295d313eca2c6843b", "288x512"),
        "studio-panorama.jpg": ("image/jpeg", "dae71b0ec014c22c914cb123062ca9233aab26b9dd35fd97ac12ee4f76a3fcf3", "512x160"),
        "route.pdf": ("application/pdf", "854ed6c18c1401b7ecf0cc78428c17b746591f12f1eab094bdc6301b83c24bd5", nil),
        "trail.mp4": ("video/mp4", "0304933c4c7bb2c9f6931614320ac646371af2f744f89af31284b4f5781d17be", "720x720"),
    ]

    // Retained slots whose original bytes are unavailable in these three examples.
    nonisolated private static let unavailable: [String: (mime: String, hash: String, dim: String?)] = [
        "Unavailable.jpg": ("image/jpeg", String(repeating: "a1", count: 32), "480x320"),
        "Unavailable.mp4": ("video/mp4", String(repeating: "a2", count: 32), "180x320"),
        "Unavailable.pdf": ("application/pdf", String(repeating: "a3", count: 32), nil),
    ]

    nonisolated static func reference(for name: String) -> MediaAttachmentReferenceFfi {
        guard let file = files[name] ?? unavailable[name] else { preconditionFailure("Missing preview media: \(name)") }
        return .init(locators: [], ciphertextSha256: file.hash, plaintextSha256: file.hash,
                     nonceHex: String(repeating: "00", count: 12), fileName: name, mediaType: file.mime,
                     version: .v2, sourceEpoch: 1, sourceEpochIdentity: nil,
                     dim: file.dim, thumbhash: nil)
    }

    private static let availableURLs: [String: URL] = {
        guard let bundle = Bundle.main.url(forResource: "ChatPreviewMedia", withExtension: "bundle") else { return [:] }
        return files.keys.reduce(into: [:]) { urls, name in
            let url = bundle.appendingPathComponent(name)
            if FileManager.default.isReadableFile(atPath: url.path) { urls[name] = url }
        }
    }()

    static func url(_ name: String) -> URL? { availableURLs[name] }

    static func avatar(for seed: String) -> UIImage? {
        let name: String
        switch seed {
        case ChatPreviewThread.trailBot: name = "fox.jpg"
        case ChatPreviewThread.peer: name = "portrait.jpg"
        case ChatPreviewThread.third, ChatPreviewThread.referenceLeo: name = "studio.jpg"
        case ChatPreviewThread.elias: name = "elias.jpg"
        case ChatPreviewThread.nora: name = "nora.jpg"
        default: return nil
        }
        return avatars[name]
    }

    private static let avatars = ["portrait.jpg", "studio.jpg", "elias.jpg", "nora.jpg", "fox.jpg"].reduce(into: [String: UIImage]()) { images, name in
        if let url = url(name) { images[name] = UIImage(contentsOfFile: url.path) }
    }

    func data(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async throws -> Data {
        guard let url = Self.url(media.fileName) else { throw AttachmentReadError.unavailable }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    func automaticAttachmentByteCount(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Int? {
        if let data = media.localData { return data.count }
        return try? Self.url(media.fileName)?.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
    func fetchAhead(_ media: MessageMediaAttachment, groupIdHex: String, appState: AppState?) async -> Bool { false }
    func openHandoff(for media: MessageMediaAttachment, groupIdHex: String, appState: AppState?,
                     control: MediaFileTransferControlFfi) async throws -> AttachmentHandoffLease? { nil }
    func stopAndDrain() async {}
    func resume() {}
}
#endif

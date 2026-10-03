import Foundation

/// Admission before ImageIO/UIKit see the animation. Encoded size and view scaling alone do
/// not bound a GIF's logical canvas or the work required to composite all its frames.
nonisolated enum GIFPlaybackAdmission {
    static let maximumEdge = 4_096
    static let maximumFrames = 1_000
    static let maximumCanvasPixelsAcrossFrames = 32 * 1_024 * 1_024

    struct Metadata: Equatable, Sendable {
        let width: Int
        let height: Int
        let frameCount: Int
    }

    /// Walks bounded headers/sub-blocks only; never decompresses pixels or allocates a raster.
    static func inspect(_ data: Data) -> Metadata? {
        guard data.count >= 14, data.count <= GiphySearchClient.maximumMediaBytes else { return nil }
        var reader = Reader(bytes: Array(data))
        guard let signature = reader.take(6),
            signature == Array("GIF87a".utf8) || signature == Array("GIF89a".utf8),
            let width = reader.word(), let height = reader.word(),
            (1...maximumEdge).contains(width), (1...maximumEdge).contains(height),
            let flags = reader.byte(), reader.skip(2),
            reader.skipColorTable(flags)
        else { return nil }

        // The edge cap makes this product safe; division keeps the aggregate check independent
        // of the frame count and prevents multiplication overflow if limits change later.
        let canvasPixels = width * height
        var frames = 0
        while let marker = reader.byte() {
            switch marker {
            case 0x3B:  // Trailer: require the entire container, not a valid prefix.
                guard reader.isAtEnd, frames > 1 else { return nil }
                return Metadata(width: width, height: height, frameCount: frames)
            case 0x21:  // Extension. Every recognized extension uses bounded sub-blocks.
                guard let label = reader.byte() else { return nil }
                switch label {
                case 0xF9:
                    guard reader.byte() == 4, reader.skip(4), reader.byte() == 0 else { return nil }
                case 0xFF:
                    guard reader.byte() == 11, reader.skip(11), reader.skipSubBlocks() else { return nil }
                case 0xFE:
                    guard reader.skipSubBlocks() else { return nil }
                default:
                    // Do not admit plaintext rendering or unknown rendering extensions without
                    // an explicit resource policy for those additional drawing operations.
                    return nil
                }
            case 0x2C:  // Image descriptor; partial frames must stay inside the logical canvas.
                guard let left = reader.word(), let top = reader.word(),
                    let frameWidth = reader.word(), let frameHeight = reader.word(),
                    frameWidth > 0, frameHeight > 0,
                    left <= width, frameWidth <= width - left,
                    top <= height, frameHeight <= height - top,
                    let frameFlags = reader.byte(), frameFlags & 0x18 == 0,
                    reader.skipColorTable(frameFlags),
                    let codeSize = reader.byte(), (2...8).contains(codeSize)
                else { return nil }
                frames += 1
                guard frames <= maximumFrames,
                    canvasPixels <= maximumCanvasPixelsAcrossFrames / frames,
                    reader.skipSubBlocks()
                else { return nil }
            default:
                return nil
            }
        }
        return nil
    }

    private struct Reader {
        let bytes: [UInt8]
        private var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func byte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func word() -> Int? {
            guard let low = byte(), let high = byte() else { return nil }
            return Int(low) | (Int(high) << 8)
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - offset else { return nil }
            let result = Array(bytes[offset..<(offset + count)])
            offset += count
            return result
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= bytes.count - offset else { return false }
            offset += count
            return true
        }

        mutating func skipColorTable(_ flags: UInt8) -> Bool {
            flags & 0x80 == 0 || skip(3 * (1 << (Int(flags & 0x07) + 1)))
        }

        mutating func skipSubBlocks() -> Bool {
            while let count = byte() {
                if count == 0 { return true }
                guard skip(Int(count)) else { return false }
            }
            return false
        }
    }
}

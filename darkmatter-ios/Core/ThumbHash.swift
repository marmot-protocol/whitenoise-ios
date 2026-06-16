import Foundation
import UIKit

// ThumbHash: a compact, blurry image placeholder. We emit it as a render hint
// alongside encrypted-media uploads so recipients can show a preview before the
// full image downloads. See https://evanw.github.io/thumbhash/ for the format.
//
// The encoder below is a faithful port of the reference Swift implementation
// (github.com/evanw/thumbhash, MIT). The compound-expression decomposition and
// while-loop style are deliberate workarounds for Swift compiler/debug-build
// performance and are kept intact from the reference.
//
// Portions of this file are derived from ThumbHash by Evan Wallace, used under
// the MIT License:
//
//   Copyright (c) 2023 Evan Wallace
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.
nonisolated enum ThumbHash {
    // ThumbHash encoding requires a tiny image; the reference caps usable input
    // at 100x100 and there is no quality benefit above that.
    static let maxEncodeEdge = 100

    /// Produces a base64-encoded ThumbHash string for `image`, or nil if the
    /// image cannot be rasterized. Suitable for the encrypted-media `thumbhash`
    /// render hint.
    static func encodedString(from image: UIImage) -> String? {
        guard let rgba = rgbaBytes(from: image) else { return nil }
        let hash = rgbaToThumbHash(w: rgba.width, h: rgba.height, rgba: rgba.data)
        return hash.base64EncodedString()
    }

    /// Downsamples `image` to at most `maxEncodeEdge` on its long side and draws
    /// it into a straight-alpha RGBA8 buffer. Marmot media uploads are opaque
    /// JPEGs, so premultiplied vs straight alpha is equivalent here, but we keep
    /// the buffer little-endian RGBA to match the ThumbHash encoder's byte order.
    private static func rgbaBytes(from image: UIImage) -> (width: Int, height: Int, data: Data)? {
        guard let cgImage = image.cgImage else { return nil }
        let srcWidth = cgImage.width
        let srcHeight = cgImage.height
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        let longest = max(srcWidth, srcHeight)
        let scale = longest > maxEncodeEdge ? Double(maxEncodeEdge) / Double(longest) : 1
        let width = max(1, Int((Double(srcWidth) * scale).rounded()))
        let height = max(1, Int((Double(srcHeight) * scale).rounded()))

        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (width, height, buffer)
    }

    // MARK: - Reference encoder (evanw/thumbhash, MIT)

    private static func rgbaToThumbHash(w: Int, h: Int, rgba: Data) -> Data {
        // Encoding an image larger than 100x100 is slow with no benefit
        assert(w <= 100 && h <= 100)
        assert(rgba.count == w * h * 4)

        // Determine the average color
        var avg_r: Float32 = 0
        var avg_g: Float32 = 0
        var avg_b: Float32 = 0
        var avg_a: Float32 = 0
        rgba.withUnsafeBytes { rgba in
            var rgba = rgba.baseAddress!.bindMemory(to: UInt8.self, capacity: rgba.count)
            let n = w * h
            var i = 0
            while i < n {
                let alpha = Float32(rgba[3]) / 255
                avg_r += alpha / 255 * Float32(rgba[0])
                avg_g += alpha / 255 * Float32(rgba[1])
                avg_b += alpha / 255 * Float32(rgba[2])
                avg_a += alpha
                rgba = rgba.advanced(by: 4)
                i += 1
            }
        }
        if avg_a > 0 {
            avg_r /= avg_a
            avg_g /= avg_a
            avg_b /= avg_a
        }

        let hasAlpha = avg_a < Float32(w * h)
        let l_limit = hasAlpha ? 5 : 7 // Use fewer luminance bits if there's alpha
        let imax_wh = max(w, h)
        let iwl_limit = l_limit * w
        let ihl_limit = l_limit * h
        let fmax_wh = Float32(imax_wh)
        let fwl_limit = Float32(iwl_limit)
        let fhl_limit = Float32(ihl_limit)
        let flx = round(fwl_limit / fmax_wh)
        let fly = round(fhl_limit / fmax_wh)
        var lx = Int(flx)
        var ly = Int(fly)
        lx = max(1, lx)
        ly = max(1, ly)
        var lpqa = [Float32](repeating: 0, count: w * h * 4)

        // Convert the image from RGBA to LPQA (composite atop the average color)
        rgba.withUnsafeBytes { rgba in
            lpqa.withUnsafeMutableBytes { lpqa in
                var rgba = rgba.baseAddress!.bindMemory(to: UInt8.self, capacity: rgba.count)
                var lpqa = lpqa.baseAddress!.bindMemory(to: Float32.self, capacity: lpqa.count)
                let n = w * h
                var i = 0
                while i < n {
                    let alpha = Float32(rgba[3]) / 255
                    let r = avg_r * (1 - alpha) + alpha / 255 * Float32(rgba[0])
                    let g = avg_g * (1 - alpha) + alpha / 255 * Float32(rgba[1])
                    let b = avg_b * (1 - alpha) + alpha / 255 * Float32(rgba[2])
                    lpqa[0] = (r + g + b) / 3
                    lpqa[1] = (r + g) / 2 - b
                    lpqa[2] = r - g
                    lpqa[3] = alpha
                    rgba = rgba.advanced(by: 4)
                    lpqa = lpqa.advanced(by: 4)
                    i += 1
                }
            }
        }

        // Encode using the DCT into DC (constant) and normalized AC (varying) terms
        let encodeChannel = { (channel: UnsafePointer<Float32>, nx: Int, ny: Int) -> (Float32, [Float32], Float32) in
            var dc: Float32 = 0
            var ac: [Float32] = []
            var scale: Float32 = 0
            var fx = [Float32](repeating: 0, count: w)
            fx.withUnsafeMutableBytes { fx in
                let fx = fx.baseAddress!.bindMemory(to: Float32.self, capacity: fx.count)
                var cy = 0
                while cy < ny {
                    var cx = 0
                    while cx * ny < nx * (ny - cy) {
                        var ptr = channel
                        var f: Float32 = 0
                        var x = 0
                        while x < w {
                            let fw = Float32(w)
                            let fxx = Float32(x)
                            let fcx = Float32(cx)
                            fx[x] = cos(Float32.pi / fw * fcx * (fxx + 0.5))
                            x += 1
                        }
                        var y = 0
                        while y < h {
                            let fh = Float32(h)
                            let fyy = Float32(y)
                            let fcy = Float32(cy)
                            let fy = cos(Float32.pi / fh * fcy * (fyy + 0.5))
                            var x = 0
                            while x < w {
                                f += ptr.pointee * fx[x] * fy
                                x += 1
                                ptr = ptr.advanced(by: 4)
                            }
                            y += 1
                        }
                        f /= Float32(w * h)
                        if cx > 0 || cy > 0 {
                            ac.append(f)
                            scale = max(scale, abs(f))
                        } else {
                            dc = f
                        }
                        cx += 1
                    }
                    cy += 1
                }
            }
            if scale > 0 {
                let n = ac.count
                var i = 0
                while i < n {
                    ac[i] = 0.5 + 0.5 / scale * ac[i]
                    i += 1
                }
            }
            return (dc, ac, scale)
        }
        let (
            (l_dc, l_ac, l_scale),
            (p_dc, p_ac, p_scale),
            (q_dc, q_ac, q_scale),
            (a_dc, a_ac, a_scale)
        ) = lpqa.withUnsafeBytes { lpqa in
            let lpqa = lpqa.baseAddress!.bindMemory(to: Float32.self, capacity: lpqa.count)
            return (
                encodeChannel(lpqa, max(3, lx), max(3, ly)),
                encodeChannel(lpqa.advanced(by: 1), 3, 3),
                encodeChannel(lpqa.advanced(by: 2), 3, 3),
                hasAlpha ? encodeChannel(lpqa.advanced(by: 3), 5, 5) : (1, [], 1)
            )
        }

        // Write the constants
        let isLandscape = w > h
        let fl_dc = round(63.0 * l_dc)
        let fp_dc = round(31.5 + 31.5 * p_dc)
        let fq_dc = round(31.5 + 31.5 * q_dc)
        let fl_scale = round(31.0 * l_scale)
        let il_dc = UInt32(fl_dc)
        let ip_dc = UInt32(fp_dc)
        let iq_dc = UInt32(fq_dc)
        let il_scale = UInt32(fl_scale)
        let ihasAlpha = UInt32(hasAlpha ? 1 : 0)
        let header24 = il_dc | (ip_dc << 6) | (iq_dc << 12) | (il_scale << 18) | (ihasAlpha << 23)
        let fp_scale = round(63.0 * p_scale)
        let fq_scale = round(63.0 * q_scale)
        let ilxy = UInt16(isLandscape ? ly : lx)
        let ip_scale = UInt16(fp_scale)
        let iq_scale = UInt16(fq_scale)
        let iisLandscape = UInt16(isLandscape ? 1 : 0)
        let header16 = ilxy | (ip_scale << 3) | (iq_scale << 9) | (iisLandscape << 15)
        var hash = Data(capacity: 25)
        hash.append(UInt8(header24 & 255))
        hash.append(UInt8((header24 >> 8) & 255))
        hash.append(UInt8(header24 >> 16))
        hash.append(UInt8(header16 & 255))
        hash.append(UInt8(header16 >> 8))
        var isOdd = false
        if hasAlpha {
            let fa_dc = round(15.0 * a_dc)
            let fa_scale = round(15.0 * a_scale)
            let ia_dc = UInt8(fa_dc)
            let ia_scale = UInt8(fa_scale)
            hash.append(ia_dc | (ia_scale << 4))
        }

        // Write the varying factors
        for ac in [l_ac, p_ac, q_ac] {
            for f in ac {
                let f15 = round(15.0 * f)
                let i15 = UInt8(f15)
                if isOdd {
                    hash[hash.count - 1] |= i15 << 4
                } else {
                    hash.append(i15)
                }
                isOdd = !isOdd
            }
        }
        if hasAlpha {
            for f in a_ac {
                let f15 = round(15.0 * f)
                let i15 = UInt8(f15)
                if isOdd {
                    hash[hash.count - 1] |= i15 << 4
                } else {
                    hash.append(i15)
                }
                isOdd = !isOdd
            }
        }
        return hash
    }
}

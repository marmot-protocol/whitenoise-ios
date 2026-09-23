import SwiftUI
import UIKit

nonisolated enum WNIdentityPalette {
    static let paletteCount = 9

    static func paletteIndex(for publicKey: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in publicKey.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }

    static func color(for publicKey: String) -> Color {
        nameColors[paletteIndex(for: publicKey)]
    }

    // Resolve only nine dynamic colors; rows share them across profile updates.
    private static let nameColors: [Color] = (0..<paletteCount).map { index in
        Color(
            uiColor: UIColor { traits in
                let base = baseColor(at: index).resolvedColor(with: traits)
                let label = UIColor.label.resolvedColor(with: traits)
                let background = UIColor.systemBackground.resolvedColor(with: traits)
                return accessibleColor(base: base, toward: label, over: background)
            }
        )
    }

    static func avatarBackground(for publicKey: String) -> Color {
        Color(uiColor: baseColor(at: paletteIndex(for: publicKey)))
    }

    private static func baseColor(at index: Int) -> UIColor {
        switch index {
        case 0: .systemRed
        case 1: .systemOrange
        case 2: .systemGreen
        case 3: .systemTeal
        case 4: .systemBlue
        case 5: .systemIndigo
        case 6: .systemPurple
        case 7: .systemPink
        default: .systemBrown
        }
    }

    private static func accessibleColor(
        base: UIColor,
        toward label: UIColor,
        over background: UIColor
    ) -> UIColor {
        let minimumContrast: CGFloat = 4.5
        guard contrastRatio(base, background) < minimumContrast else { return base }

        var lowerBound: CGFloat = 0
        var upperBound: CGFloat = 1
        for _ in 0..<12 {
            let amount = (lowerBound + upperBound) / 2
            let candidate = mix(base, label, amount: amount)
            if contrastRatio(candidate, background) >= minimumContrast {
                upperBound = amount
            } else {
                lowerBound = amount
            }
        }
        return mix(base, label, amount: upperBound)
    }

    private static func mix(_ first: UIColor, _ second: UIColor, amount: CGFloat) -> UIColor {
        let firstComponents = components(first)
        let secondComponents = components(second)
        return UIColor(
            red: firstComponents.red + (secondComponents.red - firstComponents.red) * amount,
            green: firstComponents.green + (secondComponents.green - firstComponents.green) * amount,
            blue: firstComponents.blue + (secondComponents.blue - firstComponents.blue) * amount,
            alpha: firstComponents.alpha + (secondComponents.alpha - firstComponents.alpha) * amount
        )
    }

    private static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat {
        let value = components(color)
        return 0.2126 * linearized(value.red)
            + 0.7152 * linearized(value.green)
            + 0.0722 * linearized(value.blue)
    }

    private static func linearized(_ value: CGFloat) -> CGFloat {
        value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func components(
        _ color: UIColor
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return (0, 0, 0, 1)
        }
        return (red, green, blue, alpha)
    }
}

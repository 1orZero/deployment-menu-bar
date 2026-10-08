import SwiftUI
import UIKit

/// Colors from the pen.dev design (`.scratch/ios-companion/design/ios-companion.pen`), each with its light and dark
/// value. The app and the widget use only these.
enum Palette {
    static let background = dynamic(light: 0xF2F2F7, dark: 0x000000)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let textPrimary = dynamic(light: 0x111114, dark: 0xF5F5F7)
    static let textSecondary = dynamic(light: 0x6C6C72, dark: 0xA1A1A8)
    static let textTertiary = dynamic(light: 0xA1A1A8, dark: 0x6C6C72)
    static let separator = dynamic(light: 0xE3E3E8, dark: 0x2C2C2E)
    static let accent = dynamic(light: 0x0A66FF, dark: 0x4C8DFF)
    static let accentSoft = dynamic(light: 0xE6EFFF, dark: 0x18294A)
    static let chip = dynamic(light: 0xF2F2F7, dark: 0x2C2C2E)
    static let segmentTrack = dynamic(light: 0xE4E4EA, dark: 0x2C2C2E)
    static let vercel = dynamic(light: 0x000000, dark: 0x3A3A3C)
    static let cloudflare = dynamic(light: 0xF38020, dark: 0xF38020)
    static let ready = dynamic(light: 0x1F9D45, dark: 0x30D158)
    static let building = dynamic(light: 0xC26A00, dark: 0xFF9F0A)
    static let error = dynamic(light: 0xD92D30, dark: 0xFF453A)
    static let errorSoft = dynamic(light: 0xFDE8E8, dark: 0x3B1515)
    static let mutedState = dynamic(light: 0x7C7C83, dark: 0x8E8E93)
    static let warningBackground = dynamic(light: 0xFFF3DC, dark: 0x3A2A10)
    static let warningText = dynamic(light: 0x7A4300, dark: 0xFFD59A)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

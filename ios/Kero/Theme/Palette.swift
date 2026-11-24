import SwiftUI
import UIKit

// Kero's colors (theme.go): the sidebar's and the terminal card's, light and
// dark, and the terminal themes tuned to read on the card.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }

    /// A color with a light and a dark value, as the palette's pairs are.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(uiColor: UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    var rgba8: [UInt8] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a].map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
    }
}

enum Palette {
    static let sidebar = Color(light: 0xeceef4, dark: 0x141418)
    static let text = Color(light: 0x1d1d1f, dark: 0xececf0)
    static let textMuted = Color(light: 0x6e6e78, dark: 0xa9a9b4)
    static let textFaint = Color(light: 0xa3a3ad, dark: 0x83838f)
    static let card = Color(light: 0xffffff, dark: 0x232328)
    static let cardBorder = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.07, darkAlpha: 0.08)
    static let cardShadow = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.35)
    static let divider = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.06, darkAlpha: 0.07)
    static let chip = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.045, darkAlpha: 0.07)
    static let veil = Color(light: 0xfaf8fc, dark: 0x0e0d12, lightAlpha: 0.28, darkAlpha: 0.42)
    static let attention = Color(light: 0xc27b0f, dark: 0xf0a33a)
    static let attentionSoft = Color(light: 0xe89a28, dark: 0xf0a33a, lightAlpha: 0.13, darkAlpha: 0.15)
    static let done = Color(light: 0x1d1d1f, dark: 0xececf0)
    static let onDone = Color(light: 0xffffff, dark: 0x161618)
    static let danger = Color(light: 0xd93a35, dark: 0xff6961)
    static let accent = Color(light: 0x3b6cf6, dark: 0x6b93ff)
    static let kbd = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.04, darkAlpha: 0.06)
    static let kbdBorder = Color(light: 0x000000, dark: 0xffffff, lightAlpha: 0.09, darkAlpha: 0.1)
    static let control = Color(light: 0xffffff, dark: 0x404047)

    /// settings.HostColors, in order: a host's color is picked from its name
    /// by FNV-1a over this list, as hosts_color.go does.
    static let hostColorNames = ["red", "orange", "amber", "green", "teal", "blue", "purple", "pink"]
    static let hostColors: [String: Color] = [
        "red": Color(light: 0xd9453b, dark: 0xff7a70),
        "orange": Color(light: 0xdc6a1f, dark: 0xff9d5c),
        "amber": Color(light: 0xb8860b, dark: 0xf2c14e),
        "green": Color(light: 0x3a8f47, dark: 0x6fd27c),
        "teal": Color(light: 0x13897b, dark: 0x4fd1c0),
        "blue": Color(light: 0x3b6cf6, dark: 0x7b9fff),
        "purple": Color(light: 0x8257e6, dark: 0xb493ff),
        "pink": Color(light: 0xcf4c7c, dark: 0xf58fb5),
    ]

    static func hostColorName(name: String, chosen: String) -> String {
        if !chosen.isEmpty { return chosen }
        var h: UInt32 = 2166136261
        for b in name.lowercased().utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return hostColorNames[Int(h % UInt32(hostColorNames.count))]
    }

    static func hostColor(name: String, chosen: String) -> Color {
        hostColors[hostColorName(name: name, chosen: chosen)] ?? textMuted
    }
}

/// A terminal theme: theme.go's lightTermTheme and darkTermTheme, on the card.
struct TerminalTheme {
    var foreground: UIColor
    var background: UIColor
    var cursor: UIColor
    var selection: UIColor
    var palette: [UIColor]

    static let light = TerminalTheme(
        foreground: UIColor(hex: 0x1d1d1f), background: UIColor(hex: 0xffffff), cursor: UIColor(hex: 0x1d1d1f),
        selection: UIColor(hex: 0xcfdcfb),
        palette: [0x1d1d1f, 0xd3302f, 0x22863a, 0xb08800, 0x2f5bd8, 0xa033c4, 0x0f8199, 0x8e8e93,
                  0x5f5f66, 0xef4444, 0x2fa84f, 0xd4a017, 0x3b82f6, 0xc04ee0, 0x14a3bf, 0xb4b4bb].map { UIColor(hex: $0) })

    static let dark = TerminalTheme(
        foreground: UIColor(hex: 0xe6e6ea), background: UIColor(hex: 0x232328), cursor: UIColor(hex: 0xe6e6ea),
        selection: UIColor(hex: 0x2f4170),
        palette: [0x3a3a40, 0xff6b64, 0x4fd17a, 0xf2c14e, 0x6b9bff, 0xd07cf0, 0x4cc9e0, 0xc9c9cf,
                  0x6c6c78, 0xff8a84, 0x74e397, 0xffd479, 0x8fb3ff, 0xe09cf7, 0x7fdcec, 0xf5f5f7].map { UIColor(hex: $0) })

    static func forStyle(_ style: UIUserInterfaceStyle) -> TerminalTheme { style == .dark ? .dark : .light }

    /// The payload colors of FrameTheme: foreground, background, cursor, 16 colors.
    var framePayload: [[UInt8]] {
        [foreground.rgba8, background.rgba8, cursor.rgba8] + palette.map(\.rgba8)
    }
}

enum TerminalFont {
    static let regular = "JetBrainsMonoNF-Regular"
    static let bold = "JetBrainsMonoNF-Bold"
    static let italic = "JetBrainsMonoNF-Italic"
    static let boldItalic = "JetBrainsMonoNF-BoldItalic"

    static func font(_ name: String, size: CGFloat) -> UIFont {
        UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: name.contains("Bold") ? .bold : .regular)
    }
}

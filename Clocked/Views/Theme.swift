import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// A colour that follows the window's light or dark appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// Plain Mac window colours from board A, with the dark greys from the dark mode board.
enum Theme {
    static let window = Color.dynamic(light: 0xffffff, dark: 0x1e1e20)
    static let sidebar = Color.dynamic(light: 0xf3f2f7, dark: 0x29292c)
    static let sidebarSelection = Color.dynamic(light: 0xdcdbe3, dark: 0x3a3a3e)
    static let separator = Color.dynamic(light: 0xdedde3, dark: 0x000000)
    static let panel = Color.dynamic(light: 0xf6f6f9, dark: 0x2a2a2d)
    static let grid = Color.dynamic(light: 0xe4e4ea, dark: 0x333336)
    static let rowLine = Color.dynamic(light: 0xf0f0f3, dark: 0x2a2a2d)
    static let live = Color.dynamic(light: 0xe5484d, dark: 0xff5a5f)
    static let start = Color.dynamic(light: 0x30a46c, dark: 0x3dbd7d)
    static let accent = Color.dynamic(light: 0x5b5bd6, dark: 0x6e6ef0)
}

/// Company colours. Each is brightened a little for dark mode.
enum Palette {
    private static let pairs: [(light: UInt32, dark: UInt32)] = [
        (0x5b5bd6, 0x6e6ef0), (0x30a46c, 0x3dbd7d), (0xf76b15, 0xff8a3d), (0xd6409f, 0xe85cb0),
        (0x0d9488, 0x2bb5a8), (0xe5484d, 0xff5a5f), (0x0090ff, 0x3aa7ff), (0xffc53d, 0xffd060),
        (0x8e4ec6, 0xa76ae0), (0xa18072, 0xb8978a), (0x3e63dd, 0x5b7ff0), (0x8e8e93, 0xa0a0a6),
    ]

    static var indices: Range<Int> { pairs.indices }

    static func color(_ index: Int) -> Color {
        let pair = pairs[((index % pairs.count) + pairs.count) % pairs.count]
        return .dynamic(light: pair.light, dark: pair.dark)
    }
}

struct CompanyDot: View {
    let company: Company
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(Palette.color(company.colorIndex)).frame(width: size, height: size)
    }
}

/// Small grey caps label used for section and card titles.
struct CapsLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
    }
}

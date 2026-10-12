import AppKit
import SwiftUI

// Tokens sampled from design/screenshots (screens-ivory.png, screens-smoked.png).
// Ivory = light appearance, Smoked = dark. Values are eyeballed from PNGs; tune against the app.
enum Theme {
    static let canvas        = dynamic(ivory: 0xF0EBE0, smoked: 0x303945)
    static let panel         = dynamic(ivory: 0xF5EEE2, smoked: 0x242D39)
    static let toast         = dynamic(ivory: 0xF3ECDE, smoked: 0x1F242D)
    static let selectedRow   = dynamic(ivory: 0xEBDED4, smoked: 0x39424F)
    static let divider       = dynamic(ivory: 0xE0D8CC, smoked: 0x3A424D)
    static let well          = dynamic(ivory: 0xE9E0D4, smoked: 0x2E343C) // note quote, kbd chips
    static let textPrimary   = dynamic(ivory: 0x1E1A17, smoked: 0xE8E7E5)
    static let textSecondary = dynamic(ivory: 0x6B625A, smoked: 0xA3A3A8)
    static let accent        = dynamic(ivory: 0x7A1F2B, smoked: 0x7FB8E8) // oxblood / ice blue
    static let thumbDark     = Color(hex: 0x1B1D22)

    enum Font {
        static let headline = SwiftUI.Font.system(size: 30, design: .serif) // onboarding titles
        static let query    = SwiftUI.Font.system(size: 15)
        static let title    = SwiftUI.Font.system(size: 13, weight: .medium)
        static let body     = SwiftUI.Font.system(size: 13)
        static let caption  = SwiftUI.Font.system(size: 11)
        static let label    = SwiftUI.Font.system(size: 10, weight: .medium).monospaced() // "RECENT"
    }

    enum Radius {
        static let panel: CGFloat = 12
        static let card: CGFloat = 8
        static let chip: CGFloat = 5
    }

    // Timings from the PRD and the design annotations.
    enum Motion {
        static let keepGlowFade = 1.2      // menu bar mark glow, "glow fades over 1.2 s"
        static let toastVisible = 1.5      // "Kept" toast
        static let searchDebounce = 0.150
        static let deleteUndo = 5.0
        static let voiceHoldThreshold = 0.4
    }

    private static func dynamic(ivory: UInt32, smoked: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: smoked) : NSColor(hex: ivory)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

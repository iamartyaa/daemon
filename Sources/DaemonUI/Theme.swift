import AppKit
import SwiftUI

// Tokens sampled from design/screenshots (screens-ivory.png, screens-smoked.png).
// Ivory = light appearance, Smoked = dark.
public enum Theme {
    static let panelTop      = dynamic(ivory: 0xF6F0E2, smoked: 0x27313D)
    static let panelBottom   = dynamic(ivory: 0xF2EBDE, smoked: 0x1E242D)
    static let windowNS      = dynamicNS(ivory: 0xF4ECDE, smoked: 0x262B33) // onboarding, settings
    static let window        = Color(nsColor: windowNS)
    static let selectedRow   = dynamic(ivory: 0xECDED4, smoked: 0x39424F)
    static let divider       = dynamic(ivory: 0xE1DACE, smoked: 0x3A4350)
    static let border        = dynamic(ivory: 0xE3DACB, smoked: 0x3A4350)  // panel and toast outline
    static let well          = dynamic(ivory: 0xE9E0D4, smoked: 0x2E353F)  // note quote, badges
    static let kbd           = dynamic(ivory: 0xEDE5D9, smoked: 0x2F3741)  // key cap fill
    static let kbdBorder     = dynamic(ivory: 0xD5CBBD, smoked: 0x4A5361)
    static let textPrimary   = dynamic(ivory: 0x1E1A17, smoked: 0xE8E7E5)
    static let textSecondary = dynamic(ivory: 0x6B625A, smoked: 0xA3A6AD)
    static let textTertiary  = dynamic(ivory: 0x8E857B, smoked: 0x7C828C)
    static let accentNS      = dynamicNS(ivory: 0x7A1F2B, smoked: 0x7FB8E8) // oxblood / ice blue
    static let accent        = Color(nsColor: accentNS)
    static let onAccent      = dynamic(ivory: 0xFBF5EC, smoked: 0x12202E) // text on accent fills
    static let thumbDark     = Color(hex: 0x1D1F25)
    static let thumbLight    = dynamic(ivory: 0xF5F1EA, smoked: 0xF3F1EC)
    static let thumbLine     = Color(hex: 0x5A5D66)
    static let toastShadow   = dynamic(ivory: 0x3A2616, smoked: 0x06080B)  // warm umber in Ivory, near-black in Smoked
    static let toastEdge     = dynamic(ivory: 0xFFFDF8, smoked: 0x56606E)  // top-edge light on the toast card

    enum Font {
        static let headline = SwiftUI.Font.system(size: 34, design: .serif) // onboarding titles
        static let menuTitle = SwiftUI.Font.system(size: 17, design: .serif)
        static let query    = SwiftUI.Font.system(size: 16.5)
        static let title    = SwiftUI.Font.system(size: 13)
        static let previewTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body     = SwiftUI.Font.system(size: 13)
        static let chip     = SwiftUI.Font.system(size: 12.5)
        static let caption  = SwiftUI.Font.system(size: 11.5)
        static let small    = SwiftUI.Font.system(size: 11)
        static let footerKey = SwiftUI.Font.system(size: 14)
        static let label    = SwiftUI.Font.system(size: 11, weight: .medium).monospaced() // "RECENT"
        static let mono     = SwiftUI.Font.system(size: 12).monospacedDigit()
    }

    enum Radius {
        static let panel: CGFloat = 14
        static let toast: CGFloat = 12
        static let toastThumb: CGFloat = 7
        static let card: CGFloat = 8
        static let thumb: CGFloat = 6
        static let chip: CGFloat = 14
        static let kbd: CGFloat = 4
        static let button: CGFloat = 7
    }

    enum Size {
        static let recallPanel = CGSize(width: 720, height: 480)
        static let toastCard = CGSize(width: 340, height: 64)   // Kept and voice; notices hug their text
        static let toastThumb: CGFloat = 40
        static let toast = CGSize(width: 384, height: 168)   // transparent panel: room for the note row and the shadow
        static let onboarding = CGSize(width: 640, height: 440)
    }

    // Timings from the PRD and the design annotations.
    enum Motion {
        static let keepGlowFade = 1.2      // menu bar mark glow, "glow fades over 1.2 s"
        static let toastVisible = 1.5      // "Kept" toast
        static let searchDebounce = 0.150
        static let deleteUndo = 5.0
        static let toastFade = 0.18
        static let toastEnter = 0.26       // drop in from the menu bar, strong ease-out
        static let toastExit = 0.16        // leave faster than it came
        static let toastSwap = 0.22        // one keep replacing another in place
        static let toastHandoff = 0.9      // voice toast waits this long for its Kept toast
        static let toastMessage = 2.0...5.0 // notices stay long enough to read, ~18 characters a second
        static let accessibilityPoll = 0.5
    }

    private static func dynamic(ivory: UInt32, smoked: UInt32) -> Color {
        Color(nsColor: dynamicNS(ivory: ivory, smoked: smoked))
    }

    private static func dynamicNS(ivory: UInt32, smoked: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: smoked) : NSColor(hex: ivory)
        }
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

extension ShapeStyle where Self == LinearGradient {
    static var panelFill: LinearGradient {
        LinearGradient(colors: [Theme.panelTop, Theme.panelBottom], startPoint: .top, endPoint: .bottom)
    }
}

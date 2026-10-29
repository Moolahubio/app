import SwiftUI
import UIKit

// Semantic colour tokens (DESIGN.md v2 A1.2 to A1.6). Every token is a dynamic
// UIColor with light, dark, dark-elevated (sheets and popovers in dark mode)
// and Increase Contrast values. Use tokens only: no raw hex outside this file,
// no `.opacity()` on a token, no `Color.primary` / `.secondary` (A1.8 rule 1).

extension UIColor {
    /// 0xRRGGBB to an sRGB colour.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// One token, resolved per trait collection (A-R `moolaToken`).
    /// - light / dark: base values.
    /// - darkElevated: dark mode at `userInterfaceLevel == .elevated` (sheets, popovers).
    /// - lightIC / darkIC / darkElevatedIC: `accessibilityContrast == .high`.
    /// A nil value means "same as the column to its left in that appearance" (A1.2).
    static func moolaToken(
        light: UInt32,
        dark: UInt32,
        darkElevated: UInt32? = nil,
        lightIC: UInt32? = nil,
        darkIC: UInt32? = nil,
        darkElevatedIC: UInt32? = nil
    ) -> UIColor {
        UIColor { traits in
            let ic = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                if traits.userInterfaceLevel == .elevated {
                    let base = darkElevated ?? dark
                    return UIColor(hex: ic ? (darkElevatedIC ?? darkIC ?? base) : base)
                }
                return UIColor(hex: ic ? (darkIC ?? dark) : dark)
            }
            return UIColor(hex: ic ? (lightIC ?? light) : light)
        }
    }
}

/// UIKit versions of the tokens (UIKit interop, launch assets, the mark).
public enum PaletteUIColor {
    // Grounds
    public static let canvas = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x000000, darkElevated: 0x1C1C1C)
    public static let sheetCanvas = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x1C1C1C, darkElevated: 0x1C1C1C)
    public static let headerBand = UIColor.moolaToken(light: 0xF6F6F6, dark: 0x0F0F0F)
    // Fills
    public static let surface = UIColor.moolaToken(light: 0xF7F7F7, dark: 0x141414, darkElevated: 0x262626)
    public static let fill = UIColor.moolaToken(light: 0xF0F0F0, dark: 0x1F1F1F, darkElevated: 0x2C2C2C)
    public static let fillPressed = UIColor.moolaToken(light: 0xE6E6E6, dark: 0x2C2C2C, darkElevated: 0x333333)
    public static let selectionPill = UIColor.moolaToken(light: 0xF3F3F3, dark: 0x141414, darkElevated: 0x262626)
    // Lines
    public static let divider = UIColor.moolaToken(
        light: 0xEBEBEB, dark: 0x242424, darkElevated: 0x333333,
        lightIC: 0xA6A6A6, darkIC: 0x6B6B6B, darkElevatedIC: 0x6B6B6B
    )
    public static let cardBorder = UIColor.moolaToken(
        light: 0xE5E5E5, dark: 0x2A2A2A, darkElevated: 0x383838,
        lightIC: 0x8A8A8A, darkIC: 0x7A7A7A, darkElevatedIC: 0x7A7A7A
    )
    public static let controlBorder = UIColor.moolaToken(
        light: 0x858585, dark: 0x767676, darkElevated: 0x808080,
        lightIC: 0x666666, darkIC: 0xA3A3A3, darkElevatedIC: 0xA3A3A3
    )
    public static let chevron = UIColor.moolaToken(
        light: 0xBDBDBD, dark: 0x5C5C5C, darkElevated: 0x6B6B6B,
        lightIC: 0x6B6B6B, darkIC: 0xA3A3A3, darkElevatedIC: 0xA3A3A3
    )
    // Text
    public static let textPrimary = UIColor.moolaToken(light: 0x000000, dark: 0xFFFFFF)
    public static let textSecondary = UIColor.moolaToken(
        light: 0x4F4F4F, dark: 0xB3B3B3, darkElevated: 0xBDBDBD,
        lightIC: 0x333333, darkIC: 0xD9D9D9
    )
    public static let textTertiary = UIColor.moolaToken(
        light: 0x666666, dark: 0x999999, darkElevated: 0xA3A3A3,
        lightIC: 0x474747, darkIC: 0xC2C2C2, darkElevatedIC: 0xC2C2C2
    )
    // Buttons
    public static let ctaBackground = UIColor.moolaToken(light: 0x141414, dark: 0xEBEBEB, lightIC: 0x000000, darkIC: 0xFFFFFF)
    public static let ctaPressed = UIColor.moolaToken(light: 0x3D3D3D, dark: 0xBDBDBD, lightIC: 0x333333, darkIC: 0xD6D6D6)
    public static let ctaForeground = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x000000)
    public static let ctaDisabledBackground = UIColor.moolaToken(light: 0xDEDEDE, dark: 0x1A1A1A, darkElevated: 0x242424)
    public static let ctaDisabledForeground = UIColor.moolaToken(
        light: 0x707070, dark: 0x737373, darkElevated: 0x808080,
        lightIC: 0x575757, darkIC: 0xA8A8A8, darkElevatedIC: 0xB0B0B0
    )
    // Accent and status
    public static let jadeText = UIColor.moolaToken(light: 0x0A6E4E, dark: 0x3DD196, lightIC: 0x075A3F, darkIC: 0x7AE6B8)
    public static let jadeFill = UIColor.moolaToken(light: 0x0B8A60, dark: 0x30C58A, lightIC: 0x0A6E4E, darkIC: 0x5CDDA6)
    public static let jadeTint = UIColor.moolaToken(light: 0xE3F4EC, dark: 0x0F2A1E, darkElevated: 0x16362A)
    public static let progressTrack = UIColor.moolaToken(light: 0xE6E6E6, dark: 0x2A2A2A, darkElevated: 0x383838)
    public static let amberText = UIColor.moolaToken(light: 0x92400E, dark: 0xF7B748, lightIC: 0x763309, darkIC: 0xFFD283)
    public static let amberTint = UIColor.moolaToken(light: 0xFDF3E1, dark: 0x2B2010, darkElevated: 0x35291A)
    public static let redText = UIColor.moolaToken(light: 0xB42318, dark: 0xFF7066, lightIC: 0x8F1B12, darkIC: 0xFF9A93)
    public static let redTint = UIColor.moolaToken(light: 0xFDECEA, dark: 0x2E1513, darkElevated: 0x3A1C19)
    // On an identity band (premium bar DS-4)
    public static let bandRaised = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x16362A)
    public static let bandRaisedNeutral = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x2C2C2C)
    // Identity (premium bar DS-2, ruling 55)
    public static let identityForeground = UIColor(hex: 0xFFFFFF)

    // Brand mark artwork (unchanged from v1; the logo only)
    public static let markJade = UIColor(hex: 0x0E9E6E)
    public static let markRing = UIColor.moolaToken(light: 0x0E9E6E, dark: 0xFFFFFF)
}

/// SwiftUI colour tokens (A1.2). Grounds, fills, lines, text, buttons, status.
public enum Palette {
    // Grounds
    /// Page ground of every full screen. Never painted inside an iOS 26 sheet (A4.4).
    public static let canvas = Color(uiColor: PaletteUIColor.canvas)
    /// Sheet background on iOS 17 and 18 only (`SheetChrome`).
    public static let sheetCanvas = Color(uiColor: PaletteUIColor.sheetCanvas)
    /// Home's greeting band and Group detail's identity band.
    public static let headerBand = Color(uiColor: PaletteUIColor.headerBand)
    // Fills
    /// Tiles (goal tiles, action tiles, the person card).
    public static let surface = Color(uiColor: PaletteUIColor.surface)
    /// Text fields, tonal and destructive buttons, chips, neutral pills and tiles, avatars, skeletons.
    public static let fill = Color(uiColor: PaletteUIColor.fill)
    /// Pressed rows, tiles, chips and tonal buttons; keypad press circle; skeletons inside a tile.
    public static let fillPressed = Color(uiColor: PaletteUIColor.fillPressed)
    /// The inset selection pill only (A8.13, A8.21): `#F3F3F3` in light, a
    /// 1.11 : 1 step on `canvas` (`surface` was 1.07), and `surface`'s values
    /// in dark (1.14 : 1, 1.13 in sheets).
    public static let selectionPill = Color(uiColor: PaletteUIColor.selectionPill)
    // Lines
    public static let divider = Color(uiColor: PaletteUIColor.divider)
    /// 1 pt edge of outlined cards; the Increase Contrast edge on tiles, tonal buttons, emoji tiles.
    public static let cardBorder = Color(uiColor: PaletteUIColor.cardBorder)
    /// Text field boundary with Increase Contrast, unselected radio rings, upcoming timeline nodes.
    public static let controlBorder = Color(uiColor: PaletteUIColor.controlBorder)
    /// Row disclosure chevrons only.
    public static let chevron = Color(uiColor: PaletteUIColor.chevron)
    // Text
    public static let textPrimary = Color(uiColor: PaletteUIColor.textPrimary)
    public static let textSecondary = Color(uiColor: PaletteUIColor.textSecondary)
    /// Placeholders, empty "$0", disabled keys, failed amounts, the lowest meta tier.
    public static let textTertiary = Color(uiColor: PaletteUIColor.textTertiary)
    // Buttons
    /// The one ink action colour: primary fill, selected chip, toast, the app tint.
    public static let ctaBackground = Color(uiColor: PaletteUIColor.ctaBackground)
    public static let ctaPressed = Color(uiColor: PaletteUIColor.ctaPressed)
    public static let ctaForeground = Color(uiColor: PaletteUIColor.ctaForeground)
    public static let ctaDisabledBackground = Color(uiColor: PaletteUIColor.ctaDisabledBackground)
    public static let ctaDisabledForeground = Color(uiColor: PaletteUIColor.ctaDisabledForeground)
    // Accent and status
    /// Money in, "Your turn", "Goal reached", positive notices, the selected tab item.
    public static let jadeText = Color(uiColor: PaletteUIColor.jadeText)
    /// Progress fills, paid nodes, the receipt's done symbol, chart bars, `Toggle`. Never behind text.
    public static let jadeFill = Color(uiColor: PaletteUIColor.jadeFill)
    /// The jade goal tile and identity band, positive pills and notices.
    public static let jadeTint = Color(uiColor: PaletteUIColor.jadeTint)
    public static let progressTrack = Color(uiColor: PaletteUIColor.progressTrack)
    /// "behind", "Past target date", "May be out of date", the test-money notice. Not "Processing…".
    public static let amberText = Color(uiColor: PaletteUIColor.amberText)
    public static let amberTint = Color(uiColor: PaletteUIColor.amberTint)
    /// Errors, "Didn't go through", destructive labels, field errors.
    public static let redText = Color(uiColor: PaletteUIColor.redText)
    public static let redTint = Color(uiColor: PaletteUIColor.redTint)
    // On an identity band (A1.5, A8.32)
    /// The tile and the progress track on a jade identity band: one step above
    /// the band (white in light, `#16362A` on `#0F2A1E` in dark), never a black hole.
    public static let bandRaised = Color(uiColor: PaletteUIColor.bandRaised)
    /// The same on a neutral band (`fill` `#1F1F1F` in dark): `#2C2C2C`.
    public static let bandRaisedNeutral = Color(uiColor: PaletteUIColor.bandRaisedNeutral)
    // Identity (A1.9)
    /// White: initials and glyphs on an `IdentityTint` fill, in every appearance.
    public static let identityForeground = Color(uiColor: PaletteUIColor.identityForeground)
    /// The system's own destructive red, for a destructive item in a system
    /// `Menu` (A1.7: system components keep system colours). The ink tint of
    /// each tab's stack (A1.6) otherwise reaches the item's icon, drawing an
    /// ink trash glyph beside the system-red "Delete goal".
    public static let systemDestructive = Color(uiColor: .systemRed)
}

/// A goal's identity tint from the API `color` string (A1.5). Only "jade"
/// exists in the data (server default, iOS create, seed); anything else,
/// empty or missing is the neutral tile.
public enum GoalTint {
    public static func color(forAPIKey key: String?) -> Color {
        switch key?.lowercased() {
        case "jade": Palette.jadeTint
        default: Palette.fill
        }
    }

    /// What sits on the goal's own identity band (the 72 pt tile, the 6 pt
    /// track, their skeletons): one step above the band whose tint is
    /// `color(forAPIKey:)` (A1.5, A8.32; premium bar DS-4).
    public static func bandRaised(forAPIKey key: String?) -> Color {
        switch key?.lowercased() {
        case "jade": Palette.bandRaised
        default: Palette.bandRaisedNeutral
        }
    }
}

/// A person's identity colour (DESIGN.md A1.9; ruling 55, premium bar DS-2):
/// a saturated fill under white initials or a white glyph, for a group of
/// distinct things, used once per screen. In wave 1 that is people only (the
/// group's AvatarStack and Members, you on Account). Never jade, amber or red:
/// they mean money in, attention and failure. The light values are the
/// premium judge's; the dark ones are the same hues lifted so the shape keeps
/// 3 : 1 on every dark ground it sits on (`surface`, `headerBand`, `canvas`;
/// the elevated values in sheets), with white on them at 5.48 : 1 or more
/// (4.84 : 1 elevated). Increase Contrast deepens each fill (one value in
/// light, dark and sheets) until white on it reaches 7 : 1, as A1.4 asks of
/// text there, and every component that draws one adds a 1 pt `cardBorder`,
/// which carries the shape's edge (3.45 : 1 on white, 4.89 : 1 on black).
public enum IdentityTint: CaseIterable, Hashable, Sendable {
    case cobalt, ocean, berry, graphite

    public var uiColor: UIColor {
        switch self {
        case .cobalt: Self.cobaltColor
        case .ocean: Self.oceanColor
        case .berry: Self.berryColor
        case .graphite: Self.graphiteColor
        }
    }

    public var color: Color { Color(uiColor: uiColor) }

    /// The same person gets the same colour on every screen and every launch:
    /// FNV-1a (32-bit) over the lower-cased key's UTF-8 bytes, modulo 4. Never
    /// `hashValue`, which Swift seeds per launch. The key is the person's
    /// handle: `CircleMember.name` for a member, `AuthUser.username ??
    /// AuthUser.name` for you.
    public static func `for`(key: String) -> IdentityTint {
        allCases[index(forKey: key)]
    }

    /// The people of one list in distinct colours (P5: each colour names a
    /// different thing): no two keys share a tint while an unused tint
    /// remains, and past four people the tints are reused evenly. Keys are
    /// taken in lower-cased order; each keeps its `for(key:)` tint unless a
    /// key before it holds that tint, and then takes the next least-used
    /// tint after it in `allCases` order. So the result depends only on the
    /// set of keys, never on their order, and a screen's stack and rows agree.
    /// Keys match case-insensitively, as in `for(key:)`; every key passed has
    /// an entry. `View.identityTints(forKeys:)` applies it to a screen.
    public static func distinct(forKeys keys: [String]) -> [String: IdentityTint] {
        var uses = Array(repeating: 0, count: allCases.count)
        var byKey: [String: IdentityTint] = [:]
        for key in Set(keys.map { $0.lowercased() }).sorted() {
            let preferred = index(forKey: key)
            let fewest = uses.min() ?? 0
            let chosen = (0..<allCases.count)
                .map { (preferred + $0) % allCases.count }
                .first { uses[$0] == fewest } ?? preferred
            uses[chosen] += 1
            byKey[key] = allCases[chosen]
        }
        return Dictionary(keys.map { ($0, byKey[$0.lowercased()] ?? .for(key: $0)) }) { first, _ in first }
    }

    /// FNV-1a (32-bit) over the lower-cased key's UTF-8 bytes, modulo 4.
    private static func index(forKey key: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % UInt32(allCases.count))
    }

    private static let cobaltColor = UIColor.moolaToken(
        light: 0x2557B8, dark: 0x2A63D1, darkElevated: 0x366DD7,
        lightIC: 0x2453B1, darkIC: 0x2453B1, darkElevatedIC: 0x2453B1
    )
    private static let oceanColor = UIColor.moolaToken(
        light: 0x0F6E8C, dark: 0x0F7290, darkElevated: 0x117B9C,
        lightIC: 0x0D5F7A, darkIC: 0x0D5F7A, darkElevatedIC: 0x0D5F7A
    )
    private static let berryColor = UIColor.moolaToken(
        light: 0xA0306A, dark: 0xB63778, darkElevated: 0xC43C82,
        lightIC: 0x9A2E66, darkIC: 0x9A2E66, darkElevatedIC: 0x9A2E66
    )
    private static let graphiteColor = UIColor.moolaToken(
        light: 0x5B5B5B, dark: 0x696969, darkElevated: 0x717171,
        lightIC: 0x585858, darkIC: 0x585858, darkElevatedIC: 0x585858
    )
}

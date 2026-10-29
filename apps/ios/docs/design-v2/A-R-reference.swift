// DESIGN.md v2, Part A reference code (v2.1, after the five reviews of 2026-10-25:
// Dynamic Type caps applied outside the size owner, no hand-made Bold Text step,
// text-style fonts where a token equals a system style, `ScaledTypeFont` for words
// inside a Text, asymmetric press motion, 52 pt row emoji tile, accessibility-size
// layouts for buttons and the ErrorBanner, neutral Processing symbol, scaling
// skeletons, jade selected tab). Type-checked with
//   xcrun --sdk iphonesimulator swiftc -typecheck -swift-version 6 \
//     -target arm64-apple-ios17.0-simulator A-R-v2.1.swift
// Names follow the v1 DesignSystem (restyle in place) where the role persists.

import SwiftUI
import UIKit

// MARK: - A1 Colour

extension UIColor {
    /// 0xRRGGBB to an sRGB colour.
    convenience init(v2Hex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// One token, resolved per trait collection.
    /// - light / dark: base values.
    /// - darkElevated: dark mode at `userInterfaceLevel == .elevated` (sheets, popovers).
    /// - lightIC / darkIC / darkElevatedIC: `accessibilityContrast == .high`.
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
                let elevated = traits.userInterfaceLevel == .elevated
                if elevated {
                    let base = darkElevated ?? dark
                    return UIColor(v2Hex: ic ? (darkElevatedIC ?? darkIC ?? base) : base)
                }
                return UIColor(v2Hex: ic ? (darkIC ?? dark) : dark)
            }
            return UIColor(v2Hex: ic ? (lightIC ?? light) : light)
        }
    }
}

public enum PaletteUIColor {
    // Grounds
    public static let canvas = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x000000, darkElevated: 0x1C1C1C)
    public static let sheetCanvas = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x1C1C1C, darkElevated: 0x1C1C1C)
    public static let headerBand = UIColor.moolaToken(light: 0xF6F6F6, dark: 0x0F0F0F)
    // Fills
    public static let surface = UIColor.moolaToken(light: 0xF7F7F7, dark: 0x141414, darkElevated: 0x262626)
    public static let fill = UIColor.moolaToken(light: 0xF0F0F0, dark: 0x1F1F1F, darkElevated: 0x2C2C2C)
    public static let fillPressed = UIColor.moolaToken(light: 0xE6E6E6, dark: 0x2C2C2C, darkElevated: 0x333333)
    // Lines
    public static let divider = UIColor.moolaToken(light: 0xEBEBEB, dark: 0x242424, darkElevated: 0x333333,
                                                   lightIC: 0xA6A6A6, darkIC: 0x6B6B6B, darkElevatedIC: 0x6B6B6B)
    public static let cardBorder = UIColor.moolaToken(light: 0xE5E5E5, dark: 0x2A2A2A, darkElevated: 0x383838,
                                                      lightIC: 0x8A8A8A, darkIC: 0x7A7A7A, darkElevatedIC: 0x7A7A7A)
    public static let controlBorder = UIColor.moolaToken(light: 0x858585, dark: 0x767676, darkElevated: 0x808080,
                                                         lightIC: 0x666666, darkIC: 0xA3A3A3, darkElevatedIC: 0xA3A3A3)
    public static let chevron = UIColor.moolaToken(light: 0xBDBDBD, dark: 0x5C5C5C, darkElevated: 0x6B6B6B,
                                                   lightIC: 0x6B6B6B, darkIC: 0xA3A3A3, darkElevatedIC: 0xA3A3A3)
    // Text
    public static let textPrimary = UIColor.moolaToken(light: 0x000000, dark: 0xFFFFFF)
    public static let textSecondary = UIColor.moolaToken(light: 0x4F4F4F, dark: 0xB3B3B3, darkElevated: 0xBDBDBD,
                                                         lightIC: 0x333333, darkIC: 0xD9D9D9)
    public static let textTertiary = UIColor.moolaToken(light: 0x666666, dark: 0x999999, darkElevated: 0xA3A3A3,
                                                        lightIC: 0x474747, darkIC: 0xC2C2C2, darkElevatedIC: 0xC2C2C2)
    // Buttons
    public static let ctaBackground = UIColor.moolaToken(light: 0x141414, dark: 0xEBEBEB, lightIC: 0x000000, darkIC: 0xFFFFFF)
    public static let ctaPressed = UIColor.moolaToken(light: 0x3D3D3D, dark: 0xBDBDBD, lightIC: 0x333333, darkIC: 0xD6D6D6)
    public static let ctaForeground = UIColor.moolaToken(light: 0xFFFFFF, dark: 0x000000)
    public static let ctaDisabledBackground = UIColor.moolaToken(light: 0xDEDEDE, dark: 0x1A1A1A, darkElevated: 0x242424)
    public static let ctaDisabledForeground = UIColor.moolaToken(light: 0x707070, dark: 0x737373, darkElevated: 0x808080,
                                                                 lightIC: 0x575757, darkIC: 0xA8A8A8, darkElevatedIC: 0xB0B0B0)
    // Accent and status
    public static let jadeText = UIColor.moolaToken(light: 0x0A6E4E, dark: 0x3DD196, lightIC: 0x075A3F, darkIC: 0x7AE6B8)
    public static let jadeFill = UIColor.moolaToken(light: 0x0B8A60, dark: 0x30C58A, lightIC: 0x0A6E4E, darkIC: 0x5CDDA6)
    public static let jadeTint = UIColor.moolaToken(light: 0xE3F4EC, dark: 0x0F2A1E, darkElevated: 0x16362A)
    public static let progressTrack = UIColor.moolaToken(light: 0xE6E6E6, dark: 0x2A2A2A, darkElevated: 0x383838)
    public static let amberText = UIColor.moolaToken(light: 0x92400E, dark: 0xF7B748, lightIC: 0x763309, darkIC: 0xFFD283)
    public static let amberTint = UIColor.moolaToken(light: 0xFDF3E1, dark: 0x2B2010, darkElevated: 0x35291A)
    public static let redText = UIColor.moolaToken(light: 0xB42318, dark: 0xFF7066, lightIC: 0x8F1B12, darkIC: 0xFF9A93)
    public static let redTint = UIColor.moolaToken(light: 0xFDECEA, dark: 0x2E1513, darkElevated: 0x3A1C19)
    // Brand mark (artwork colour, unchanged from v1)
    public static let markJade = UIColor(v2Hex: 0x0E9E6E)
}

public enum Palette {
    public static let canvas = Color(uiColor: PaletteUIColor.canvas)
    public static let sheetCanvas = Color(uiColor: PaletteUIColor.sheetCanvas)
    public static let headerBand = Color(uiColor: PaletteUIColor.headerBand)
    public static let surface = Color(uiColor: PaletteUIColor.surface)
    public static let fill = Color(uiColor: PaletteUIColor.fill)
    public static let fillPressed = Color(uiColor: PaletteUIColor.fillPressed)
    public static let divider = Color(uiColor: PaletteUIColor.divider)
    public static let cardBorder = Color(uiColor: PaletteUIColor.cardBorder)
    public static let controlBorder = Color(uiColor: PaletteUIColor.controlBorder)
    public static let chevron = Color(uiColor: PaletteUIColor.chevron)
    public static let textPrimary = Color(uiColor: PaletteUIColor.textPrimary)
    public static let textSecondary = Color(uiColor: PaletteUIColor.textSecondary)
    public static let textTertiary = Color(uiColor: PaletteUIColor.textTertiary)
    public static let ctaBackground = Color(uiColor: PaletteUIColor.ctaBackground)
    public static let ctaPressed = Color(uiColor: PaletteUIColor.ctaPressed)
    public static let ctaForeground = Color(uiColor: PaletteUIColor.ctaForeground)
    public static let ctaDisabledBackground = Color(uiColor: PaletteUIColor.ctaDisabledBackground)
    public static let ctaDisabledForeground = Color(uiColor: PaletteUIColor.ctaDisabledForeground)
    public static let jadeText = Color(uiColor: PaletteUIColor.jadeText)
    public static let jadeFill = Color(uiColor: PaletteUIColor.jadeFill)
    public static let jadeTint = Color(uiColor: PaletteUIColor.jadeTint)
    public static let progressTrack = Color(uiColor: PaletteUIColor.progressTrack)
    public static let amberText = Color(uiColor: PaletteUIColor.amberText)
    public static let amberTint = Color(uiColor: PaletteUIColor.amberTint)
    public static let redText = Color(uiColor: PaletteUIColor.redText)
    public static let redTint = Color(uiColor: PaletteUIColor.redTint)
}

/// Goal tile tint from the API `color` string. Only "jade" exists in the
/// data today (server default, iOS create, seed). Anything else: neutral.
public enum GoalTint {
    public static func color(forAPIKey key: String?) -> Color {
        switch key?.lowercased() {
        case "jade": Palette.jadeTint
        default: Palette.fill
        }
    }
}

// MARK: - A2 Typography

public enum TypeToken: CaseIterable, Hashable, Sendable {
    // Figures (SF Pro Rounded, tabular digits)
    case displayHero, displayEntry, displayAmount, amountCard, amountRow, amountSmall, keypad, code
    // Text (SF Pro)
    case titleLarge, title1, title2, greeting, title3
    case headline, body, bodyEmphasis, callout
    case subheadline, subheadlineEmphasis
    case footnote, footnoteEmphasis

    public var size: CGFloat {
        switch self {
        case .displayHero, .displayEntry: 40
        case .displayAmount, .titleLarge: 34
        case .keypad, .code: 28
        case .title1: 25
        case .title2, .greeting: 21
        case .title3, .amountCard: 19
        case .headline, .body, .bodyEmphasis, .callout, .amountRow: 16
        case .subheadline, .subheadlineEmphasis, .amountSmall: 14
        case .footnote: 13
        case .footnoteEmphasis: 12
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .displayHero, .displayEntry, .displayAmount, .amountCard, .titleLarge, .title1, .title2, .title3: .bold
        case .bodyEmphasis: .bold   // v2.1: the person's own goal and group names (Bold row title)
        case .amountRow, .keypad, .code, .greeting, .headline, .subheadlineEmphasis, .footnoteEmphasis: .medium
        case .amountSmall, .body, .callout, .subheadline, .footnote: .regular
        }
    }

    public var design: Font.Design {
        switch self {
        case .displayHero, .displayEntry, .displayAmount, .amountCard, .amountRow, .amountSmall, .keypad, .code: .rounded
        default: .default
        }
    }

    /// The Dynamic Type curve each size scales along. Chosen so no role
    /// overtakes the role above it at any of the 12 Dynamic Type sizes.
    public var relativeTo: Font.TextStyle {
        switch self {
        case .displayHero, .displayEntry, .displayAmount: .largeTitle
        case .titleLarge, .keypad, .code: .title
        case .title1, .title2, .greeting: .title2
        case .title3, .amountCard: .title3
        case .headline, .body, .bodyEmphasis, .callout, .amountRow: .callout
        case .subheadline, .subheadlineEmphasis, .amountSmall, .footnote: .footnote
        case .footnoteEmphasis: .caption
        }
    }

    /// Extra space between lines (SwiftUI `lineSpacing`).
    public var lineSpacing: CGFloat {
        switch self {
        case .title1: 3
        case .title2, .greeting: 1
        case .body, .callout, .headline, .bodyEmphasis, .subheadline, .subheadlineEmphasis, .footnote: 2
        default: 0
        }
    }

    /// Points of tracking. 0 everywhere except the verification code.
    public var tracking: CGFloat { self == .code ? 8 : 0 }

    /// Largest Dynamic Type size this style follows (nil = no cap).
    public var cap: DynamicTypeSize? {
        switch self {
        case .displayHero: .accessibility2
        case .displayEntry, .keypad, .code: .accessibility1
        case .displayAmount: .accessibility3
        default: nil
        }
    }

    public var isFigure: Bool { design == .rounded }

    /// The system text style whose default size and Dynamic Type curve equal this
    /// token's exactly (16 pt on `.callout`, 13 on `.footnote`, 12 on `.caption`).
    /// These tokens use a text-style font, which UIKit and the accessibility audit
    /// see as Dynamic Type; the others need `@ScaledMetric`.
    public var systemTextStyle: Font.TextStyle? {
        switch self {
        case .headline, .body, .bodyEmphasis, .callout, .amountRow: .callout
        case .footnote: .footnote
        case .footnoteEmphasis: .caption
        default: nil
        }
    }

    /// The token's font at an already scaled size (ignored for text-style tokens).
    public func font(scaledSize: CGFloat) -> Font {
        let base: Font
        if let style = systemTextStyle {
            base = .system(style, design: design, weight: weight)
        } else {
            base = .system(size: scaledSize, weight: weight, design: design)
        }
        return isFigure ? base.monospacedDigit() : base
    }
}

/// `Font.system(size:)` is fixed, so the size goes through `@ScaledMetric(relativeTo:)`.
/// Bold Text: never stepped by hand. SwiftUI steps SF Pro and SF Pro Rounded once
/// itself (variable weight axis; review-platform r2/probe_psname.swift).
struct TypeTokenModifier: ViewModifier {
    let token: TypeToken
    @ScaledMetric private var size: CGFloat

    init(_ token: TypeToken) {
        self.token = token
        _size = ScaledMetric(wrappedValue: token.size, relativeTo: token.relativeTo)
    }

    func body(content: Content) -> some View {
        content
            .font(token.font(scaledSize: size))
            .tracking(token.tracking)
            .lineSpacing(token.lineSpacing)
    }
}

extension View {
    /// The Dynamic Type cap is applied OUTSIDE the modifier that owns the
    /// `@ScaledMetric`, so the size itself stops growing at the cap (A2.4).
    @ViewBuilder public func textStyle(_ token: TypeToken) -> some View {
        if let cap = token.cap {
            modifier(TypeTokenModifier(token)).dynamicTypeSize(...cap)
        } else {
            modifier(TypeTokenModifier(token))
        }
    }
}

/// A token's font for a word inside a `Text` interpolation (A2.5 rule 10), e.g.
/// `@ScaledTypeFont(.subheadlineEmphasis) private var emphasis` then
/// `Text("\(Text(state))\(Text(" · Your turn").font(emphasis).foregroundStyle(Palette.jadeText))")`.
/// Text tokens only: figure tokens with a Dynamic Type cap use `.textStyle(_:)`.
@propertyWrapper
public struct ScaledTypeFont: DynamicProperty {
    private let token: TypeToken
    @ScaledMetric private var size: CGFloat

    public init(_ token: TypeToken) {
        self.token = token
        _size = ScaledMetric(wrappedValue: token.size, relativeTo: token.relativeTo)
    }

    public var wrappedValue: Font { token.font(scaledSize: size) }
}

// MARK: - A3 Layout

public enum Spacing {
    // Scale (v1 names and values kept)
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24
    public static let space8: CGFloat = 32
    public static let space10: CGFloat = 40
    // Roles (v2)
    public static let screenGutter: CGFloat = 16      // v1: 20
    public static let sheetPadding: CGFloat = 20      // v1: 24
    public static let sectionGap: CGFloat = 52
    public static let headingToContent: CGFloat = 16
    public static let gridGap: CGFloat = 12
    public static let labelToField: CGFloat = 12
    public static let fieldToNextLabel: CGFloat = 20
}

public enum Radius {
    public static let small: CGFloat = 6     // v1 8
    public static let medium: CGFloat = 10   // v1 12: buttons, fields, banners
    public static let large: CGFloat = 14    // v1 16
    public static let card: CGFloat = 14     // v1 20: tiles and cards
    public static let control: CGFloat = 10  // alias of medium
}

public enum Size {
    public static let minimumTapTarget: CGFloat = 44
    public static let button: CGFloat = 50
    public static let smallButton: CGFloat = 36
    public static let field: CGFloat = 52
    public static let hairline: CGFloat = 1
}

// MARK: - A5 Motion

public enum Motion {
    /// Press in: colour has NO animation (visible in the first frame); scale only.
    public static let pressIn = Animation.easeOut(duration: 0.06)
    /// Release, colour and scale: 90 % back at about 155 ms, no overshoot.
    public static let release = Animation.spring(duration: 0.25, bounce: 0)
    public static let standard = Animation.spring(duration: 0.3, bounce: 0)
    public static let figure = Animation.spring(duration: 0.35, bounce: 0)
    public static let exit = Animation.easeIn(duration: 0.2)
    /// Label and spinner swap inside a button (A5.3).
    public static let swap = Animation.easeOut(duration: 0.15)
    public static let reduced = Animation.easeInOut(duration: 0.2)
    /// Reduce Motion release: colour only.
    public static let reducedRelease = Animation.easeOut(duration: 0.15)

    public static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

// MARK: - A5/A8 Buttons

public enum MoolaButtonKind: Sendable { case primary, secondary, destructive, plain }

public struct MoolaButtonStyle: ButtonStyle {
    public var kind: MoolaButtonKind = .primary
    public var fullWidth = true
    public var small = false

    public init(kind: MoolaButtonKind = .primary, fullWidth: Bool = true, small: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
        self.small = small
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, kind: kind, fullWidth: fullWidth, small: small)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: MoolaButtonKind
        let fullWidth: Bool
        let small: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            let accessibilitySize = dynamicTypeSize.isAccessibilitySize
            configuration.label
                // A8.11: a leading symbol (Label icon) is dropped at accessibility sizes;
                // the words already name the method ("Confirm with Face ID").
                .labelStyle(MoolaButtonLabelStyle(showsIcon: !accessibilitySize))
                .textStyle(.headline)
                // Labels never truncate: 2 lines at the default sizes, unlimited at AX sizes.
                .lineLimit(accessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .plain ? 0 : (small ? 14 : 20))
                .padding(.vertical, kind == .plain || small ? 0 : (accessibilitySize ? 12 : 0))
                .frame(maxWidth: fullWidth && kind != .plain ? .infinity : nil)
                .frame(minHeight: kind == .plain ? Size.minimumTapTarget : (small ? Size.smallButton : Size.button))
                .background(background(pressed: pressed), in: shape)
                .opacity(kind == .plain && pressed ? 0.5 : 1)
                // Colour and opacity: instant on touch-down, eased on release (A5.2).
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .overlay {
                    if kind != .plain, kind != .primary, contrast == .increased {
                        shape.strokeBorder(Palette.cardBorder, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle().inset(by: small ? -4 : 0))
                .scaleEffect(pressed && !reduceMotion && kind != .plain ? 0.97 : 1)
                .animation(pressed ? Motion.pressIn : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
        }

        private var foreground: Color {
            guard isEnabled else {
                return kind == .plain ? Palette.textTertiary : Palette.ctaDisabledForeground
            }
            switch kind {
            case .primary: return Palette.ctaForeground
            case .secondary, .plain: return Palette.textPrimary
            case .destructive: return Palette.redText
            }
        }

        private func background(pressed: Bool) -> Color {
            if kind == .plain { return .clear }
            guard isEnabled else { return Palette.ctaDisabledBackground }
            switch kind {
            case .primary: return pressed ? Palette.ctaPressed : Palette.ctaBackground
            case .secondary, .destructive: return pressed ? Palette.fillPressed : Palette.fill
            case .plain: return .clear
            }
        }
    }
}

/// The button label: an optional leading symbol (18 pt Medium, scaled with the
/// label) 8 pt before the title (A8.11).
public struct MoolaButtonLabelStyle: LabelStyle {
    public var showsIcon = true
    public init(showsIcon: Bool = true) { self.showsIcon = showsIcon }
    public func makeBody(configuration: Configuration) -> some View {
        LabelBody(configuration: configuration, showsIcon: showsIcon)
    }
    private struct LabelBody: View {
        let configuration: LabelStyleConfiguration
        let showsIcon: Bool
        @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 18
        var body: some View {
            HStack(spacing: Spacing.space2) {
                if showsIcon {
                    configuration.icon
                        .font(.system(size: iconSize, weight: .medium))
                        .accessibilityHidden(true)
                }
                configuration.title
            }
        }
    }
}

/// Tappable tiles and cards: pressed fill, scale 0.98 (none under Reduce Motion).
public struct PressableCardButtonStyle: ButtonStyle {
    public var restingFill: Color
    public var cornerRadius: CGFloat = Radius.card

    public init(restingFill: Color = Palette.surface, cornerRadius: CGFloat = Radius.card) {
        self.restingFill = restingFill
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, restingFill: restingFill, cornerRadius: cornerRadius)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let restingFill: Color
        let cornerRadius: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background(pressed ? Palette.fillPressed : restingFill,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .animation(pressed ? Motion.pressIn : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
        }
    }
}

/// Containers only for tappable or decision objects (A3.7, A8.5).
/// `fill: false` on tappable tiles and cards: the fill (and its pressed state)
/// comes from `PressableCardButtonStyle`, so it is not hidden under a second fill.
struct TileStyle: ViewModifier {
    var fill = true
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(Spacing.space4)
            .background(fill ? Palette.surface : Color.clear, in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: 1) }
            }
    }
}

struct OutlinedCardStyle: ViewModifier {
    var fill = true
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(Spacing.space4)
            .background(fill ? Palette.canvas : Color.clear, in: shape)
            .overlay { shape.strokeBorder(Palette.cardBorder, lineWidth: 1) }
    }
}

extension View {
    public func tileStyle(fill: Bool = true) -> some View { modifier(TileStyle(fill: fill)) }
    public func outlinedCardStyle(fill: Bool = true) -> some View { modifier(OutlinedCardStyle(fill: fill)) }
}

/// A tappable tile: the button style draws the fill, `.tileStyle(fill: false)`
/// adds the padding and the Increase Contrast edge.
struct TappableTileExample: View {
    var body: some View {
        Button {} label: {
            Text("Emergency fund")
                .frame(maxWidth: .infinity, alignment: .leading)
                .tileStyle(fill: false)
        }
        .buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
    }
}

/// Full-width list rows: the row background turns `fillPressed` at once while
/// held and fades back with `Motion.release` (A5.2).
public struct RowButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }
    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(pressed ? Palette.fillPressed : Color.clear)
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
        }
    }
}

// MARK: - A6 Haptics (one call site pattern)

struct HapticsPattern: View {
    @State private var confirmCount = 0
    @State private var rejectedKeys = 0
    @State private var failures = 0
    @State private var receiptDone = false
    var body: some View {
        Button("Confirm") { confirmCount += 1 }
            .buttonStyle(MoolaButtonStyle(kind: .primary))
            .sensoryFeedback(.impact(weight: .medium), trigger: confirmCount)
            .sensoryFeedback(.warning, trigger: rejectedKeys)
            .sensoryFeedback(.error, trigger: failures)
            .sensoryFeedback(.success, trigger: receiptDone) { old, new in !old && new }
    }
}

// MARK: - A7 Emoji identity tile

public enum EmojiIdentity {
    /// The string to draw, or nil for the neutral tile. One grapheme only.
    public static func displayEmoji(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first else { return nil }
        let scalars = trimmed.unicodeScalars
        if first.properties.isEmojiPresentation { return trimmed }
        if scalars.contains(where: { $0.value == 0x20E3 }) { return trimmed }
        guard first.properties.isEmoji, !first.isASCII else { return nil }
        return scalars.contains { $0.value == 0xFE0F } ? trimmed : trimmed + "\u{FE0F}"
    }
}

/// v2.1: rows and goal tiles use 52 (was 44), which matches the goal row's
/// 53.3 pt text block. 32 keeps a 14 pt glyph (16 measured 0.57 to 0.62 of the
/// tile, too full).
public enum EmojiTileSize: CGFloat, CaseIterable, Sendable {
    case s32 = 32, s52 = 52, s56 = 56, s72 = 72
    public var cornerRadius: CGFloat {
        switch self { case .s32: 9; case .s52: 14; case .s56: 16; case .s72: 20 }
    }
    /// Apple Color Emoji ink is about 0.98 em, so a glyph of half the side fills
    /// about half the tile (32 pt takes 14 pt).
    public var emojiPointSize: CGFloat {
        switch self { case .s32: 14; case .s52: 26; case .s56: 28; case .s72: 36 }
    }
    /// Neutral-tile initial (SF Pro Medium).
    public var initialPointSize: CGFloat {
        switch self { case .s32: 13; case .s52: 21; case .s56: 23; case .s72: 30 }
    }
}

/// Identity art for a goal (or a streak). Hidden from VoiceOver: the row's
/// label is the goal name. Never used in labels, buttons, money copy,
/// navigation, headings, empty states, toasts or notifications.
public struct EmojiTile: View {
    let emoji: String?
    let colorKey: String?
    let fallbackName: String?
    let size: EmojiTileSize
    /// The tile's fill when it sits on its own identity band (Goal detail): `canvas`,
    /// so a jade tile never disappears into a jade band (B3.11). nil = the A1.5 tint.
    var groundOverride: Color? = nil
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    public init(emoji: String?, colorKey: String?, fallbackName: String?, size: EmojiTileSize,
                groundOverride: Color? = nil) {
        self.emoji = emoji
        self.colorKey = colorKey
        self.fallbackName = fallbackName
        self.size = size
        self.groundOverride = groundOverride
    }

    public var body: some View {
        let factor = min(scale, 1.5)
        let side = size.rawValue * factor
        let glyph = EmojiIdentity.displayEmoji(emoji)
        let tint = groundOverride ?? (glyph == nil ? Palette.fill : GoalTint.color(forAPIKey: colorKey))
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius * factor, style: .continuous)
        ZStack {
            shape.fill(tint)
            if let glyph {
                Text(verbatim: glyph)
                    .font(.system(size: size.emojiPointSize * factor))
            } else if let initial = Self.initial(of: fallbackName) {
                Text(verbatim: initial)
                    .font(.system(size: size.initialPointSize * factor, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .overlay {
            if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: 1) }
        }
        .accessibilityHidden(true)
    }

    static func initial(of name: String?) -> String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }
}

/// Create goal emoji picker cell: a 56 pt jade tile; selected = 2 pt ink ring
/// 4 pt outside the tile (concentric radius 20). The ring is shape, not colour.
/// The ring, its gap and the cell scale by the tile's own factor (≤ 1.5), so the
/// ring stays concentric at accessibility sizes.
struct EmojiPickerCell: View {
    let emoji: String
    let label: String
    let identifier: String
    let isSelected: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    var body: some View {
        let factor = min(scale, 1.5)
        Button(action: action) {
            EmojiTile(emoji: emoji, colorKey: "jade", fallbackName: nil, size: .s56)
                .padding(4 * factor)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 20 * factor, style: .continuous)
                            .strokeBorder(Palette.ctaBackground, lineWidth: 2)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 72 * factor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - A4 Chrome

struct TabBarNeverMinimizes: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

/// Every sheet: detents, the grabber, the ink tint (so a sheet presented from
/// inside the jade-tinted `TabView` never inherits the tab tint), and on iOS 17/18
/// the opaque `sheetCanvas`.
struct SheetChrome: ViewModifier {
    let detents: Set<PresentationDetent>
    func body(content: Content) -> some View {
        let base = content
            .tint(Palette.ctaBackground)
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
        if #available(iOS 26.0, *) {
            base
        } else {
            base.presentationBackground(Palette.sheetCanvas)
        }
    }
}

/// Fallback for A11.2 item 4, used only if iOS 17 or 18 do not pass the dark
/// elevated level into sheet content: `SheetChrome` then adds this zero-size
/// controller, which sets the iOS 17 `traitOverrides` on its sheet's controller.
/// Not built while the system does it (verified on iOS 26.5).
struct ElevatedTraitOverride: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Controller() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Controller: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            parent?.traitOverrides.userInterfaceLevel = .elevated
        }
    }
}

/// Close for sheets. The identifier is the caller's (default "Close"; Savings
/// passes "savings.sheet.close", Add test money "home.addMoney.close").
/// Placement: `ToolbarItem(placement: .cancellationAction)` on a sheet's first
/// step; `ToolbarItem(placement: .topBarTrailing)` on a pushed step. Never
/// `.confirmationAction`: iOS 26.5 draws that as a filled, ink-tinted prominent
/// glass circle, so Close would look like the confirm action (review-prototype B3).
struct SheetCloseButton: View {
    var identifier: String = "Close"
    let action: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityIdentifier(identifier)
        } else {
            Button("Close", systemImage: "xmark", action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - A8.23 ErrorBanner (v1 API names kept; adds an optional title)

/// Red-tint banner inside the margins. Accessibility as v1: one combined
/// element, announced on appear. At accessibility sizes the action moves under
/// the message (leading, 44 pt minimum height) so the message keeps the full
/// width; the symbol scales with the text (A7.1). At accessibility sizes a
/// banner never sits in a pinned bar: it moves into the scroll content (A8.30).
struct ErrorBanner: View {
    let title: String?
    let message: String
    let retryTitle: String
    let retry: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var symbolSlot: CGFloat = 20

    init(_ message: String, title: String? = nil, retryTitle: String = "Try again", retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(Palette.redText)
                .frame(width: symbolSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .textStyle(.subheadlineEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(message)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if stacked, retry != nil { action.padding(.top, Spacing.space1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked, retry != nil { action }
        }
        .padding(Spacing.space3)
        .background(Palette.redTint, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .onAppear {
            AccessibilityNotification.Announcement([title, message].compactMap { $0 }.joined(separator: " ")).post()
        }
    }

    @ViewBuilder private var action: some View {
        if let retry {
            Button(action: retry) {
                Text(retryTitle)
                    .textStyle(.subheadlineEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - A8.26 PickerField (a field-styled button that opens a value step or a date popover)

/// VoiceOver value: `accessibilityValue` when the caller passes one, else the shown
/// value, else "empty". Callers whose empty value is tested pass it: Sign up's date
/// of birth passes `date?.formatted(date: .long, time: .omitted) ?? "Choose a date"`
/// (AuthFlowUITests.swift:482); Create goal's target keeps "empty".
struct PickerField: View {
    let label: String
    let value: String?
    let placeholder: String
    var accessibilityValue: String? = nil
    var trailingSymbol = "chevron.forward"
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .callout) private var chevronSize: CGFloat = 14
    @ScaledMetric(relativeTo: .callout) private var calendarSize: CGFloat = 18

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let isCalendar = trailingSymbol == "calendar"
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                Text(value ?? placeholder)
                    .textStyle(.body)
                    .monospacedDigit()
                    .foregroundStyle(value == nil || !isEnabled ? Palette.textTertiary : Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: trailingSymbol)
                    .font(.system(size: isCalendar ? calendarSize : chevronSize,
                                  weight: isCalendar ? .regular : .semibold))
                    .foregroundStyle(isCalendar ? Palette.textSecondary : Palette.chevron)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space2)     // as v1 fields: grows past 70 pt at AX5
            .frame(minHeight: Size.field)
            .contentShape(shape)
        }
        .buttonStyle(PickerFieldStyle(shape: shape, enabled: isEnabled))
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? value ?? "empty")
    }

    private struct PickerFieldStyle: ButtonStyle {
        let shape: RoundedRectangle
        let enabled: Bool
        func makeBody(configuration: Configuration) -> some View {
            PickerFieldBody(configuration: configuration, shape: shape, enabled: enabled)
        }
    }

    private struct PickerFieldBody: View {
        let configuration: ButtonStyleConfiguration
        let shape: RoundedRectangle
        let enabled: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .background(pressed ? Palette.fillPressed : Palette.fill, in: shape)
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                // Ruling 54 (2.2): borderless at rest, like MoolaTextField; the 1 pt boundary only with Increase Contrast.
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(enabled ? Palette.controlBorder : Palette.divider, lineWidth: 1)
                    }
                }
        }
    }
}

// MARK: - A5 Figures, receipt symbol, skeleton

/// The figure's motion (A5.5). Spoken in full words, as `MoneyText` does
/// (`Money.accessibilityText()` in the app; tests parse "N,NNN.NN US dollars").
struct AmountFigure: View {
    let cents: Int
    var token: TypeToken = .displayHero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let enUS = Locale(identifier: "en_US")
    var body: some View {
        Text(Decimal(cents) / 100, format: .currency(code: "USD").locale(Self.enUS))
            .textStyle(token)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(cents)))
            .animation(reduceMotion ? Motion.reduced : Motion.figure, value: cents)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityLabel(Text(Decimal(cents) / 100,
                                     format: .currency(code: "USD").presentation(.fullName).locale(Self.enUS)))
    }
}

enum ReceiptStatus: Equatable { case processing, done, failed }

/// Opens on Processing (neutral: the normal state right after a send, so no
/// status colour); turns Done (jade) or Didn't go through (red) when the
/// Activity match arrives. Bounce only on Done; no effects under Reduce Motion.
/// 56 pt fixed: a decorative mark hidden from VoiceOver (A7.1 exemption).
struct ReceiptSymbol: View {
    let status: ReceiptStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 56, weight: .regular))
            .symbolRenderingMode(status == .processing ? .monochrome : .palette)
            .foregroundStyle(primary, secondary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: status == .done)
            .symbolEffectsRemoved(reduceMotion)
            .accessibilityHidden(true)
    }
    private var name: String {
        switch status {
        case .processing: "clock"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
    private var primary: Color {
        switch status {
        case .processing: Palette.textSecondary
        case .done, .failed: Palette.canvas
        }
    }
    private var secondary: Color {
        switch status {
        case .processing: Palette.textSecondary
        case .done: Palette.jadeFill
        case .failed: Palette.redText
        }
    }
}

/// A value's stand-in at its real size (A5.7). A text bar passes the replaced
/// style's `relativeTo`, so the bar grows with Dynamic Type like the text it
/// replaces; blocks for tiles, fields and media pass nil (fixed). Inside a
/// `surface` tile the caller passes `Palette.fillPressed` (`fill` on `surface` is
/// 1.06 : 1). Reduce Motion is read live: turning it on mid-pulse holds the
/// block at full opacity.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    @ScaledMetric private var height: CGFloat
    var cornerRadius: CGFloat = 4
    var color: Color = Palette.fill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    init(width: CGFloat? = nil, height: CGFloat, relativeTo style: Font.TextStyle? = nil,
         cornerRadius: CGFloat = 4, color: Color = Palette.fill) {
        self.width = width
        _height = ScaledMetric(wrappedValue: height, relativeTo: style ?? .body)
        self.cornerRadius = cornerRadius
        self.color = color
        self.isFixed = style == nil
        self.fixedHeight = height
    }

    private let isFixed: Bool
    private let fixedHeight: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: width, height: isFixed ? fixedHeight : height)
            .opacity(reduceMotion ? 1 : (dimmed ? 0.55 : 1))
            .onAppear { startPulse() }
            .onChange(of: reduceMotion) { _, _ in startPulse() }
            .accessibilityHidden(true)
    }

    private func startPulse() {
        guard !reduceMotion, !dimmed else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// The selected tab is the one jade item in the chrome: on iOS 26 the glass bar
/// draws unselected items in the label colour, so an ink tint left the selected
/// tab 1.05 : 1 (light) from the others (review-taste B1). Each tab's
/// `NavigationStack` restores the ink tint for its content (toolbar symbols,
/// `DatePicker`, links).
struct TabsExample: View {
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            tab("Home", "house", 0)
            tab("Savings", "flag", 1)
            tab("Groups", "person.3", 2)
            tab("Activity", "list.bullet.rectangle.portrait", 3)
            tab("Account", "person.crop.circle", 4)
        }
        .tint(Palette.jadeText)
        .modifier(TabBarNeverMinimizes())
    }

    private func tab(_ title: String, _ symbol: String, _ tag: Int) -> some View {
        NavigationStack { Text(title) }
            .tint(Palette.ctaBackground)
            .tabItem { Label(title, systemImage: symbol) }
            .tag(tag)
    }
}

/// Inline navigation titles are SF Pro 21 Bold (founder decision 1). Text
/// attributes only, so the iOS 26 glass and scroll edge effect stay
/// system-drawn (research-platform R16).
/// Call once at launch; large titles keep the system's 34 Bold.
enum NavigationBarFonts {
    @MainActor
    static func applyInlineTitle(size: CGFloat = 21, weight: UIFont.Weight = .bold) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        UINavigationBar.appearance().titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: font),
        ]
    }
}

/// The identity band of the person's own item (B3.11 Goal detail: the goal's A1.5
/// tint; B4.13 Group detail: `headerBand`). Full bleed, from the screen's top edge
/// (behind the status bar and the glass inline bar) to 24 pt below its last line.
/// Opaque content, not glass. Use it with `IdentityBandScreen` on the scroll view and
/// `BelowIdentityBand` on the content after it.
struct IdentityBand<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
    }
}

/// On the screen's `ScrollView`: the scroll view's ground is the band tint and, on
/// iOS 26, the top scroll edge is `.hard`. Measured on iOS 26.5 (proto-v2,
/// shots-v2.1/exp-*): at rest the band runs behind the status bar and the glass bar;
/// scrolled, the hard edge paints the bar region in the band tint (the bar keeps the
/// item's colour) and a full-width ink button never
/// smears into the bar. Pull to refresh opens band colour above the band.
struct IdentityBandScreen: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .modifier(HardTopScrollEdge())
            .background(tint)
    }
}

/// On the content after the band: `canvas`, extended 2,000 pt below the content so
/// a bottom overscroll never shows the band tint.
struct BelowIdentityBand: ViewModifier {
    func body(content: Content) -> some View {
        content.background(alignment: .top) {
            Palette.canvas.padding(.bottom, -2000)
        }
    }
}

/// Pushed screens whose content holds a full-width ink primary (Goal detail,
/// Group detail) and the screens with an identity band use the hard top edge on
/// iOS 26: the soft edge smeared the button into the bar (status bar 1.88 : 1).
struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

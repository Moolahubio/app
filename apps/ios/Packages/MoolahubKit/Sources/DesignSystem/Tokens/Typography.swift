import SwiftUI
import UIKit

/// The type scale (DESIGN.md v2 A2.3). SF Pro for every word, SF Pro Rounded
/// with tabular digits for money and hero figures (founder decision 1). No
/// bundled fonts. Sizes follow Dynamic Type along each token's `relativeTo`
/// curve (A2.4); figure tokens stop at their cap. Regular, Medium and Bold
/// only; tracking 0 except `code`. Bold Text is never stepped by hand: the
/// system steps SF Pro and SF Pro Rounded once itself (A2.5 rule 6).
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
        // The names of the person's own goals and groups (Bold row title, 2.1).
        case .bodyEmphasis: .bold
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

    /// The Dynamic Type curve each size scales along, chosen so no role
    /// overtakes the role above it at any of the 12 sizes (A2.4).
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

    /// Points of tracking: 0 everywhere except the verification code (A2.5 rule 5).
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

    /// SF Pro Rounded with tabular digits.
    public var isFigure: Bool { design == .rounded }

    /// The cap height of the token's default size, to one decimal: SF Pro and
    /// SF Pro Rounded put it at 0.705 of the size. A skeleton bar standing in
    /// for this text is this tall and scales along `relativeTo` (A5.7: `body`
    /// 11.3, `subheadline` 9.9, `footnote` 9.2, `title3` 13.4, `displayAmount`
    /// 24.0, `displayHero` 28.2). The one table of cap heights; don't type them.
    public var capHeight: CGFloat {
        (size * 0.705 * 10).rounded() / 10
    }

    /// The hero figures: one per screen, `lineLimit(1)` and `minimumScaleFactor(0.6)` (A2.5 rule 1).
    public var isDisplayAmount: Bool {
        self == .displayHero || self == .displayEntry || self == .displayAmount
    }

    /// The system text style whose default size and Dynamic Type curve equal
    /// this token's (16 pt on `.callout`, 13 on `.footnote`, 12 on `.caption`).
    /// These tokens use a text-style font, which UIKit and the accessibility
    /// audit see as Dynamic Type; the others go through `@ScaledMetric`.
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

/// Owns the size's `@ScaledMetric`; `textStyle(_:)` puts the cap outside it.
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
    /// Applies a type token: font (SF Pro or SF Pro Rounded, Dynamic Type),
    /// tracking, line spacing and the token's cap. The cap is applied OUTSIDE
    /// the modifier that owns the `@ScaledMetric`, so the size itself stops
    /// growing at the cap (A2.3, A2.4).
    @ViewBuilder public func textStyle(_ token: TypeToken) -> some View {
        if let cap = token.cap {
            modifier(TypeTokenModifier(token)).dynamicTypeSize(...cap)
        } else {
            modifier(TypeTokenModifier(token))
        }
    }
}

/// A token's font for a word inside a `Text` interpolation (A2.5 rule 10):
///
///     @ScaledTypeFont(.subheadlineEmphasis) private var emphasis
///     Text("\(Text(state))\(Text(" · Your turn").font(emphasis).foregroundStyle(Palette.jadeText))")
///
/// Text tokens only; figure tokens with a Dynamic Type cap use `.textStyle(_:)`.
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

/// Inline navigation titles are SF Pro 21 Bold (A2.5 rule 4). UIKit text
/// attributes only, so the iOS 26 glass and the scroll edge effect stay
/// system-drawn. Large titles keep the system's 34 Bold. Call once at launch.
public enum NavigationBarFonts {
    @MainActor
    public static func applyInlineTitle(size: CGFloat = 21, weight: UIFont.Weight = .bold) {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        UINavigationBar.appearance().titleTextAttributes = [
            .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: font),
        ]
    }
}

extension String {
    /// Display text whose " · " separators keep the dot at the END of a line
    /// when it wraps at large text sizes ("Available $1,264.59 ·" / "In goals
    /// $1,580.00", never a line that starts with "·"): a no-break space
    /// (U+00A0) before each middle dot. For drawn text only; spoken labels and
    /// strings that tests compare keep plain spaces.
    public var keepingMiddleDotsAtLineEnds: String {
        replacingOccurrences(of: " \u{00B7} ", with: String.lineEndMiddleDot)
    }

    /// The separator `keepingMiddleDotsAtLineEnds` produces, for text built
    /// piece by piece: a no-break space, the middle dot, a space. The one
    /// implementation of the rule; don't type U+00A0 by hand.
    public static let lineEndMiddleDot = "\u{00A0}\u{00B7} "
}

import SwiftUI

/// The goal's emoji as identity art (DESIGN.md v2 A7.4, A7.5; founder decision 2).
public enum EmojiIdentity {
    /// The string to draw, or nil for the neutral tile. One grapheme only:
    /// adds U+FE0F to a bare text-style emoji, rejects digits, `#`, letters,
    /// empty strings and two emoji.
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

    /// True when `text` contains an emoji by the predicate the copy check uses
    /// (A7.4): a scalar with `isEmojiPresentation`; a non-ASCII `isEmoji`
    /// scalar followed by U+FE0F; or U+20E3 (keycap). App strings never may.
    public static func containsEmoji(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isEmojiPresentation { return true }
            if scalar.value == 0x20E3 { return true }
            if scalar.properties.isEmoji, !scalar.isASCII,
               index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F {
                return true
            }
        }
        return false
    }
}

/// Tile sizes (A7.5): 32 (review and receipt "To"/"From" values), 52 (goal
/// rows and tiles, the identity media column), 56 (the Create goal picker),
/// 72 (the Goal detail identity band).
public enum EmojiTileSize: CGFloat, CaseIterable, Sendable {
    case s32 = 32, s52 = 52, s56 = 56, s72 = 72

    public var cornerRadius: CGFloat {
        switch self {
        case .s32: 9
        case .s52: 14
        case .s56: 16
        case .s72: 20
        }
    }

    /// Apple Color Emoji ink is about 0.98 em, so half the side fills about half the tile.
    public var emojiPointSize: CGFloat {
        switch self {
        case .s32: 14
        case .s52: 26
        case .s56: 28
        case .s72: 36
        }
    }

    /// The neutral tile's initial (SF Pro Medium).
    public var initialPointSize: CGFloat {
        switch self {
        case .s32: 13
        case .s52: 21
        case .s56: 23
        case .s72: 30
        }
    }
}

/// Identity art for a goal (or a streak): the API emoji on a soft tile in its
/// A1.5 tint (`"jade"` → `jadeTint`, anything else → `fill`). Missing or
/// invalid emoji: the neutral tile with the name's first letter in
/// `textSecondary`, or the plain neutral tile. A continuous rounded square
/// (circles are for people). Scales with Dynamic Type (`.body`), at most 1.5 ×.
/// Increase Contrast: a 1 pt `cardBorder` edge. Hidden from VoiceOver: the
/// row's label is the goal name. Never used in labels, buttons, money copy,
/// navigation, headings, empty states, toasts or notifications.
public struct EmojiTile: View {
    let emoji: String?
    let colorKey: String?
    let fallbackName: String?
    let size: EmojiTileSize
    let groundOverride: Color?

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    /// - Parameters:
    ///   - emoji: the API `emoji`, raw (not the 12-icon mapping).
    ///   - colorKey: the API `color`.
    ///   - fallbackName: the goal's name, for the neutral tile's initial.
    ///   - groundOverride: `GoalTint.bandRaised(forAPIKey:)` when the tile sits
    ///     on its own identity band (Goal detail), so a jade tile never
    ///     disappears into a jade band and is never a black hole in dark (A1.5).
    public init(emoji: String?, colorKey: String?, fallbackName: String?, size: EmojiTileSize, groundOverride: Color? = nil) {
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
            if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
        }
        .accessibilityHidden(true)
    }

    static func initial(of name: String?) -> String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }
}

/// A Create goal picker cell (A7.6): a 56 pt jade tile in a 72 pt cell, the
/// whole cell tappable. Selected: a 2 pt `ctaBackground` ring 4 pt outside the
/// tile (radius 20, concentric) plus `.isSelected`: selection is shape, not
/// colour. The ring, its gap and the cell scale with the tile (≤ 1.5 ×). The
/// tile is hidden; the button carries the label ("Travel") and identifier
/// (`savings.create.icon.travel`). Put `.sensoryFeedback(.selection, trigger:)` on the grid.
public struct EmojiPickerCell: View {
    let emoji: String
    let label: String
    let identifier: String
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    public init(emoji: String, label: String, identifier: String, isSelected: Bool, action: @escaping () -> Void) {
        self.emoji = emoji
        self.label = label
        self.identifier = identifier
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let factor = min(scale, 1.5)
        Button(action: action) {
            EmojiTile(emoji: emoji, colorKey: "jade", fallbackName: nil, size: .s56)
                .padding(4 * factor)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 20 * factor, style: .continuous)
                            .strokeBorder(Palette.ctaBackground, lineWidth: Size.selectionRing)
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

#Preview("Emoji tiles") {
    VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
            EmojiTile(emoji: "\u{1F3AF}", colorKey: "jade", fallbackName: "Trip", size: .s32)
            EmojiTile(emoji: "\u{2602}", colorKey: "jade", fallbackName: "Rainy day", size: .s52)
            EmojiTile(emoji: nil, colorKey: "jade", fallbackName: "Laptop", size: .s56)
            EmojiTile(emoji: "\u{1F43E}", colorKey: "sky", fallbackName: "Dog", size: .s72)
        }
        EmojiPickerCell(emoji: "\u{2708}\u{FE0F}", label: "Travel", identifier: "preview.travel", isSelected: true) {}
            .frame(width: 82)
    }
    .padding()
    .moolaCanvas()
}

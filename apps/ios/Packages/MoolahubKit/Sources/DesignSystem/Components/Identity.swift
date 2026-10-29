import SwiftUI

// Identity pieces of the founder's premium bar (DESIGN.md Part K; A8.33,
// A8.34): the person raised on a card (P8), the ruling 55 identity tile
// (P5) and one list's distinct colours (`identityTints(forKeys:)`, A1.9).
// People's own circles are `AvatarView` and `AvatarStack` (A8.13).

/// The person as the one raised object on a screen (premium bar P8; the
/// Account card of PREMIUM-GAPS A-1): the person's 64 pt `AvatarView` in
/// their identity colour; 16 pt; the name (`title3` `textPrimary`),
/// "@{username}" (`subheadline` `textSecondary`, omitted when nil) and the
/// email (`subheadline` `textSecondary`, one line, middle truncation), 2 pt
/// apart; a trailing `chevron.forward` (14 pt Semibold, `chevron`). Inside
/// `.tileStyle(fill: false)` (16 pt padding, radius 14; Increase Contrast adds
/// the 1 pt `cardBorder`), full width: 96 pt tall at the default size. Use it
/// as the label of a `NavigationLink` with
/// `.buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))`,
/// which draws the `surface` fill and the press. Raised by a fill step, never a
/// shadow (A3.7: content has no shadows, and one is invisible on black). Text
/// inside a tile is the tile's own edge, so it adds no screen edge (A3.1). At
/// accessibility sizes the avatar sits above the text and the chevron stays
/// trailing; the email wraps, with a zero-width break after its "@" (B5.1).
/// No photo: photos are held this wave, the identity colour carries the
/// person (DS-2). The caller sets the link's label ("{name}, @{username},
/// {email}"), hint and identifiers.
public struct PersonCardLabel: View {
    let name: String
    let username: String?
    let email: String?
    let avatarName: String?
    let identityKey: String?

    @ScaledMetric(relativeTo: .callout) private var scaledChevronSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - avatarName: what `AvatarView` takes its initials from (Account
    ///     passes `AccountInitials.of(user.name)`).
    ///   - identityKey: `AuthUser.username ?? AuthUser.name`, the key every
    ///     other screen uses for this person; nil draws the neutral circle.
    public init(name: String, username: String?, email: String?, avatarName: String?, identityKey: String?) {
        self.name = name
        self.username = username
        self.email = email
        self.avatarName = avatarName
        self.identityKey = identityKey
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .center, spacing: Spacing.space4) {
            let layout = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space3))
                : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.space4))
            layout {
                AvatarView(name: avatarName, size: 64, identityKey: identityKey)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .textStyle(.title3)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let username {
                        Text(verbatim: "@\(username)")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let email {
                        // Stacked, the email wraps after "@" ("demo@" /
                        // "moolahub.test") and never mid-word, as B5.1's header.
                        Text(verbatim: stacked ? email.replacingOccurrences(of: "@", with: "@\u{200B}") : email)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(stacked ? nil : 1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.forward")
                .font(.system(size: SettingsRowMetrics.chevronSize(scaledChevronSize, dynamicTypeSize), weight: .semibold))
                .foregroundStyle(Palette.chevron)
                .accessibilityHidden(true)
        }
        .tileStyle(fill: false)
        .contentShape(Rectangle())
    }
}

/// Where an `IdentityTile` sits: one of A3.1's two media columns.
public enum IdentityTileSize: Sendable {
    /// 24 pt, radius 7, glyph 14 pt: in the symbol media column, where a row's
    /// bare symbol would be (text at x = 52).
    case symbol
    /// 52 pt, radius 14, glyph 24 pt: in the identity media column (text at x = 80).
    case identity

    var side: CGFloat { self == .symbol ? 24 : 52 }
    var cornerRadius: CGFloat { self == .symbol ? 7 : Radius.card }
    var glyph: CGFloat { self == .symbol ? 14 : 24 }
}

/// Ruling 55 (premium bar P5, amending A7.1's "No wells"): a white SF Symbol
/// (`identityForeground`, Medium) on a saturated `IdentityTint` fill in a
/// continuous rounded square, for ONE group of rows per screen whose members
/// are distinct things; every other row keeps its bare monochrome symbol.
/// Contrast (A1.7, A1.9): the glyph is 5.79 : 1 or more on every fill in
/// light, 5.48 : 1 in dark and 4.84 : 1 in sheets; the tile is 5.35 : 1 or
/// more against light grounds and 3.10 : 1 or more against every dark ground
/// it can sit on. Increase Contrast deepens the fill until the glyph reaches
/// 7 : 1 (A1.9) and adds a 1 pt `cardBorder` for the edge. The side, radius
/// and glyph scale along `.callout`, capped at 1.5 × (as `EmojiTile`). Hidden
/// from VoiceOver: the row's words name the thing. Wave 1 puts it on no screen
/// (PREMIUM-GAPS: Activity types and the Account settings rows stay
/// monochrome; people use `AvatarView`'s tints).
public struct IdentityTile: View {
    let systemImage: String
    let tint: IdentityTint
    let size: IdentityTileSize

    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    public init(systemImage: String, tint: IdentityTint, size: IdentityTileSize = .symbol) {
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        let factor = min(scale, 1.5)
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius * factor, style: .continuous)
        ZStack {
            shape.fill(tint.color)
            Image(systemName: systemImage)
                .font(.system(size: size.glyph * factor, weight: .medium))
                .foregroundStyle(Palette.identityForeground)
        }
        .frame(width: size.side * factor, height: size.side * factor)
        .overlay {
            if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
        }
        .accessibilityHidden(true)
    }
}

struct IdentityTintsKey: EnvironmentKey {
    static let defaultValue: [String: IdentityTint] = [:]
}

extension EnvironmentValues {
    /// One list's people in distinct colours (`identityTints(forKeys:)`),
    /// by key as passed; a key not in it keeps `IdentityTint.for(key:)`.
    var identityTints: [String: IdentityTint] {
        get { self[IdentityTintsKey.self] }
        set { self[IdentityTintsKey.self] = newValue }
    }
}

extension View {
    /// Gives the people of one list distinct identity colours
    /// (`IdentityTint.distinct(forKeys:)`; P5): every `AvatarView` and
    /// `AvatarStack` circle inside whose key is in `keys` takes its tint from
    /// that set; any other key keeps `IdentityTint.for(key:)`. Apply it once
    /// around all of a screen's people, with every named member's key (Group
    /// detail: `CircleMember.name` of each member that is not unnamed), so the
    /// stack and the rows agree.
    public func identityTints(forKeys keys: [String]) -> some View {
        environment(\.identityTints, IdentityTint.distinct(forKeys: keys))
    }
}

#if DEBUG
#Preview("Identity") {
    VStack(alignment: .leading, spacing: 16) {
        PersonCardLabel(name: "Ama Owusu", username: "ama", email: "ama@moolahub.test", avatarName: "AO", identityKey: "ama")
        HStack(spacing: 12) {
            ForEach(IdentityTint.allCases, id: \.self) { tint in
                IdentityTile(systemImage: "creditcard", tint: tint)
                IdentityTile(systemImage: "creditcard", tint: tint, size: .identity)
            }
        }
    }
    .padding(16)
    .moolaCanvas()
}
#endif

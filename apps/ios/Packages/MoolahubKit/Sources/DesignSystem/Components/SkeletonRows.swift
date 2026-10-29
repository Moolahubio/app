import SwiftUI

// Shared skeleton pieces (DESIGN.md v2 A5.7): one text line, the goal row,
// the activity row and the goal tile (`SkeletonCard` in States.swift), each
// at the final layout's real size. Features put them inside their screen's
// `LoadingPlaceholder`, which carries the one loading label and the pulse.

/// One line of text's stand-in: the line keeps the height of one line of
/// `token` (it follows Dynamic Type and the token's cap, so nothing moves
/// when the data lands), with skeleton bars as tall as the token's cap height
/// (`TypeToken.capHeight`, scaling along `token.relativeTo`): one at the
/// leading edge and optionally one at the trailing edge, each a fraction of
/// the line's width or a fixed width. Hidden from VoiceOver. Inside a
/// `surface` tile pass `Palette.fillPressed` (A5.7).
public struct SkeletonTextLine: View {
    let token: TypeToken
    let leading: CGFloat?
    let leadingWidth: CGFloat?
    let trailing: CGFloat?
    let trailingWidth: CGFloat?
    let color: Color

    /// - Parameters:
    ///   - leading: the leading bar's width as a fraction of the line (0.5 for a title).
    ///   - leadingWidth: or its width in points (a typical value's width).
    ///   - trailing / trailingWidth: an optional bar at the trailing edge (an amount).
    public init(
        _ token: TypeToken,
        leading: CGFloat? = nil,
        leadingWidth: CGFloat? = nil,
        trailing: CGFloat? = nil,
        trailingWidth: CGFloat? = nil,
        color: Color = Palette.fill
    ) {
        self.token = token
        self.leading = leading
        self.leadingWidth = leadingWidth
        self.trailing = trailing
        self.trailingWidth = trailingWidth
        self.color = color
    }

    public var body: some View {
        Text(verbatim: " ")
            .textStyle(token)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay {
                GeometryReader { proxy in
                    ZStack {
                        if let width = leadingWidth ?? leading.map({ proxy.size.width * $0 }) {
                            bar(width: width)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        }
                        if let width = trailingWidth ?? trailing.map({ proxy.size.width * $0 }) {
                            bar(width: width)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        let block = SkeletonBlock(width: width, height: token.capHeight, relativeTo: token.relativeTo, color: color)
        if let cap = token.cap {
            // The bar stops growing where the text it stands in for stops.
            block.dynamicTypeSize(...cap)
        } else {
            block
        }
    }
}

/// A goal row's skeleton (A8.6 row geometry, A3.5): the 52 pt `fill` tile
/// (radius 14), then on the text column a name bar (50 %) with the amount bar
/// (40 %) trailing, the sub-line bar (70 %) and the 4 pt track; 16 pt top and
/// 16.7 pt bottom padding (86 pt). Stacked at accessibility sizes, like the
/// row it stands in for (ruling 26). Home's goals (inset 16) and Move to
/// goal's "Choose a goal" (inset 20, a sheet) use it.
public struct GoalRowSkeleton: View {
    let inset: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(inset: CGFloat = Spacing.screenGutter) {
        self.inset = inset
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    tile
                    SkeletonTextLine(.bodyEmphasis, leading: 0.5)
                        .padding(.top, Spacing.space2)
                    SkeletonTextLine(.amountRow, leading: 0.4)
                        .padding(.top, Spacing.space1)
                    SkeletonTextLine(.subheadline, leading: 0.7)
                        .padding(.top, Spacing.space1)
                    track.padding(.top, 10)
                }
                .padding(.vertical, Spacing.space4)
            } else {
                HStack(alignment: .top, spacing: Spacing.space3) {
                    tile
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonTextLine(.bodyEmphasis, leading: 0.5, trailing: 0.4)
                        SkeletonTextLine(.subheadline, leading: 0.7)
                            .padding(.top, Spacing.space1)
                        track.padding(.top, 10)
                    }
                }
                .padding(.top, Spacing.space4)
                .padding(.bottom, Size.goalRowBottomPadding)
                .frame(minHeight: 86, alignment: .top)
            }
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tile: some View {
        SkeletonBlock(width: EmojiTileSize.s52.rawValue, height: EmojiTileSize.s52.rawValue, cornerRadius: EmojiTileSize.s52.cornerRadius)
    }

    private var track: some View {
        Capsule()
            .fill(Palette.fill)
            .frame(height: 4)
    }
}

/// An activity row's skeleton (A8.19 geometry): 64 pt, an optional 18 pt
/// block in the 24 pt symbol slot (Activity; Home's rows have no symbol), a
/// title bar (50 %) with a 64 pt amount bar trailing, and a sub-line bar
/// (30 %). Stacked at accessibility sizes, like the row.
public struct ActivityRowSkeleton: View {
    let showsSymbol: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 24

    public init(showsSymbol: Bool) {
        self.showsSymbol = showsSymbol
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    if showsSymbol { symbolBlock }
                    SkeletonTextLine(.body, leading: 0.5)
                    SkeletonTextLine(.amountRow, leadingWidth: 64)
                    SkeletonTextLine(.subheadline, leading: 0.3)
                }
                .padding(.vertical, Spacing.space3)
            } else {
                HStack(alignment: .center, spacing: Spacing.space3) {
                    if showsSymbol {
                        symbolBlock.frame(width: symbolSlot, height: symbolSlot)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        SkeletonTextLine(.body, leading: 0.5, trailingWidth: 64)
                        SkeletonTextLine(.subheadline, leading: 0.3)
                    }
                }
                .padding(.vertical, Spacing.space3)
                .frame(minHeight: 64)
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbolBlock: some View {
        SkeletonBlock(width: 18, height: 18, relativeTo: .callout)
    }
}

import SwiftUI

/// Empty state (DESIGN.md v2 A8.20, A9.7): no symbol, no circle, no
/// illustration, no emoji, no "!". A leading-aligned block (the caller puts
/// it at the gutter, 24 pt below the screen's title): title (`title2`), 8 pt,
/// body (`body` `textSecondary`, at most 3 lines), 24 pt, an optional
/// full-width primary named for what it does ("Create goal").
public struct EmptyState: View {
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.title2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space2)
            if let actionTitle, let action {
                MoolaButton(actionTitle, action: action)
                    .padding(.top, Spacing.space6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Error state when nothing loaded (A8.20, A9.8): the empty-state layout with
/// the screen's specific title ("We couldn't load your goals"), the W6 body
/// and a full-width secondary "Try again" (loading "Trying again…"). Shows no
/// "$" and no amount. The 404 variant passes its title ("We couldn't find
/// that goal."), `retryTitle: "Back to savings"` and `retryKind: .primary`.
/// If a screen had data and a refresh failed, keep the data and show an
/// `ErrorBanner` instead.
public struct ErrorState: View {
    let title: String
    let message: String?
    let retryTitle: String
    let retryKind: MoolaButtonKind
    let isRetrying: Bool
    let retry: () -> Void

    public init(
        title: String = "We couldn't load this",
        message: String?,
        isRetrying: Bool = false,
        retryTitle: String = "Try again",
        retryKind: MoolaButtonKind = .secondary,
        retry: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retryKind = retryKind
        self.isRetrying = isRetrying
        self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.title2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
            MoolaButton(
                retryTitle,
                kind: retryKind,
                loadingTitle: retryTitle == "Try again" ? "Trying again\u{2026}" : nil,
                isLoading: isRetrying,
                action: retry
            )
            .padding(.top, Spacing.space6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Skeletons (A5.7)

struct SkeletonPulseHandledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a `LoadingPlaceholder`, which pulses its whole layout once.
    var skeletonPulseHandled: Bool {
        get { self[SkeletonPulseHandledKey.self] }
        set { self[SkeletonPulseHandledKey.self] = newValue }
    }
}

/// A value's stand-in at its real size (A5.7). A text bar passes the replaced
/// style's cap height and `relativeTo` (`body` 11.3 on `.callout`, `title3`
/// 13.4 on `.title3`, `displayHero` 28.2 on `.largeTitle`, `amountRow` 11.3 on
/// `.callout`), so it grows with Dynamic Type like the text it replaces; tiles,
/// fields and media pass no style (fixed). Radius 4 for text bars, the real
/// radius otherwise. Inside a `surface` tile pass `Palette.fillPressed`.
/// One slow pulse (1.0 ↔ 0.55, 1.5 s each way), static under Reduce Motion
/// (read live). Hidden from VoiceOver: the surrounding `LoadingPlaceholder`
/// carries the loading label.
public struct SkeletonBlock: View {
    let width: CGFloat?
    @ScaledMetric private var scaledHeight: CGFloat
    let fixedHeight: CGFloat
    let isFixed: Bool
    let cornerRadius: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonPulseHandled) private var pulseHandled
    @Environment(\.skeletonPulseDimmed) private var placeholderDimmed
    @State private var dimmed = false

    public init(
        width: CGFloat? = nil,
        height: CGFloat,
        relativeTo style: Font.TextStyle? = nil,
        cornerRadius: CGFloat = 4,
        color: Color = Palette.fill
    ) {
        self.width = width
        _scaledHeight = ScaledMetric(wrappedValue: height, relativeTo: style ?? .body)
        self.fixedHeight = height
        self.isFixed = style == nil
        self.cornerRadius = cornerRadius
        self.color = color
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color)
            .frame(width: width, height: isFixed ? fixedHeight : scaledHeight)
            .opacity(reduceMotion ? 1 : ((pulseHandled ? placeholderDimmed : dimmed) ? 0.55 : 1))
            .onAppear { startPulse() }
            .onChange(of: reduceMotion) { _, _ in startPulse() }
            .accessibilityHidden(true)
    }

    private func startPulse() {
        guard !reduceMotion, !pulseHandled, !dimmed else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// One skeleton block of a fixed width or a fraction of the available width
/// (v1 API kept). Radius 4 by default (text bars); pass the real radius for
/// tiles and fields. A text bar passes the replaced style's `relativeTo`
/// (A5.7: `body` 11.3 on `.callout`, `subheadline` 9.9 on `.footnote`,
/// `displayHero` 28.2 on `.largeTitle`), so its height grows with Dynamic
/// Type like the text it stands in for; without it the height is fixed.
public struct SkeletonBar: View {
    let width: CGFloat?
    let widthFraction: CGFloat?
    let fixedHeight: CGFloat
    let isFixed: Bool
    let color: Color
    let radius: CGFloat

    @ScaledMetric private var scaledHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonPulseHandled) private var pulseHandled
    @Environment(\.skeletonPulseDimmed) private var placeholderDimmed
    @State private var dimmed = false

    public init(width: CGFloat, height: CGFloat = 14, relativeTo style: Font.TextStyle? = nil, color: Color = Palette.fill, radius: CGFloat = 4) {
        self.width = width
        self.widthFraction = nil
        self.fixedHeight = height
        self.isFixed = style == nil
        _scaledHeight = ScaledMetric(wrappedValue: height, relativeTo: style ?? .body)
        self.color = color
        self.radius = radius
    }

    public init(widthFraction: CGFloat, height: CGFloat = 14, relativeTo style: Font.TextStyle? = nil, color: Color = Palette.fill, radius: CGFloat = 4) {
        self.width = nil
        self.widthFraction = widthFraction
        self.fixedHeight = height
        self.isFixed = style == nil
        _scaledHeight = ScaledMetric(wrappedValue: height, relativeTo: style ?? .body)
        self.color = color
        self.radius = radius
    }

    public var body: some View {
        Group {
            if let widthFraction {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(color)
                        .frame(width: geometry.size.width * widthFraction)
                }
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .frame(width: width)
            }
        }
        .frame(height: isFixed ? fixedHeight : scaledHeight)
        // The same pulse as `SkeletonBlock` (A5.7).
        .opacity(reduceMotion ? 1 : ((pulseHandled ? placeholderDimmed : dimmed) ? 0.55 : 1))
        .onAppear { startPulse() }
        .onChange(of: reduceMotion) { _, _ in startPulse() }
        .accessibilityHidden(true)
    }

    private func startPulse() {
        guard !reduceMotion, !pulseHandled, !dimmed else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// The pulse a `LoadingPlaceholder` hands its skeleton blocks: one phase for
/// every block in it, so they breathe together.
struct SkeletonPulseDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var skeletonPulseDimmed: Bool {
        get { self[SkeletonPulseDimmedKey.self] }
        set { self[SkeletonPulseDimmedKey.self] = newValue }
    }
}

/// Wraps a skeleton layout (the screen's final layout with every value
/// replaced): one slow pulse that only its `SkeletonBlock`s and `SkeletonBar`s
/// follow, in step; static under Reduce Motion (read live); and one VoiceOver
/// element with the screen's loading label ("Loading your goals…", W8).
/// Everything else in it (labels, headers, the identity band, the page
/// grounds) renders at once at full opacity (A5.7): dimming the whole layout
/// made Goal detail's page breathe between the band tint and `canvas` and its
/// "Your plan" heading fade.
public struct LoadingPlaceholder<Content: View>: View {
    let label: String
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    public init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.skeletonPulseHandled, true)
            .environment(\.skeletonPulseDimmed, reduceMotion ? false : dimmed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .onAppear { startPulse() }
            .onChange(of: reduceMotion) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard !reduceMotion, !dimmed else { return }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// A goal tile while the Savings list first loads (B3.3): the tile at its
/// real size (`surface`, radius 14, padding 16; Increase Contrast adds its
/// edge) with `fillPressed` blocks (A5.7: `fill` on `surface` is 1.06 : 1) on
/// the tile's own lines: the 52 pt emoji block, the name bar (50 % of the
/// column), the amount bar (40 %), the "of $3,000" bar (65 pt), the 4 pt
/// track and the "41% · On track" bar (89 pt). Each line is reserved at the
/// loaded tile's line height, so the skeleton tile is as tall as a loaded one
/// (199 pt at the default size) at every text size.
public struct SkeletonCard: View {
    @ScaledMetric(relativeTo: .body) private var emojiScale: CGFloat = 1

    public init() {}

    public var body: some View {
        let emojiSide = EmojiTileSize.s52.rawValue * min(emojiScale, 1.5)
        VStack(alignment: .leading, spacing: 0) {
            SkeletonBlock(width: emojiSide, height: emojiSide, cornerRadius: EmojiTileSize.s52.cornerRadius, color: Palette.fillPressed)
            SkeletonTextLine(.bodyEmphasis, leading: 0.5, color: Palette.fillPressed)
                .padding(.top, Spacing.space3)
            SkeletonTextLine(.amountCard, leading: 0.4, color: Palette.fillPressed)
                .padding(.top, Spacing.space1)
            SkeletonTextLine(.amountSmall, leadingWidth: 65, color: Palette.fillPressed)
                .padding(.top, 2)
            SkeletonBar(widthFraction: 1, height: 4, color: Palette.fillPressed, radius: 2)
                .padding(.top, Spacing.space3)
            SkeletonTextLine(.footnote, leadingWidth: 89, color: Palette.fillPressed)
                .padding(.top, Spacing.space2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tileStyle()
    }
}

#Preview("States") {
    ScrollView {
        VStack(alignment: .leading, spacing: 32) {
            EmptyState(title: "No goals yet", message: "Set a target and a date. We'll track your progress.", actionTitle: "Create goal") {}
            ErrorState(title: "We couldn't load your goals", message: "We couldn't load this. Check your connection and try again.") {}
            LoadingPlaceholder(label: "Loading your goals\u{2026}") {
                HStack(spacing: 12) {
                    SkeletonCard()
                    SkeletonCard()
                }
            }
        }
        .padding(16)
    }
    .moolaCanvas()
}

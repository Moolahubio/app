import SwiftUI

/// Button kinds (DESIGN.md v2 A8.11).
public enum MoolaButtonKind: Sendable {
    /// Ink fill (`ctaBackground`), the one filled action per screen.
    case primary
    /// Tonal: `fill` with a `textPrimary` label.
    case secondary
    /// Tonal with a `redText` label; never a filled primary (HIG). Uses `role: .destructive`.
    case destructive
    /// No container: `headline` ink, pressed opacity 0.5, 44 pt hit.
    case plain
}

public enum MoolaButtonSize: Sendable {
    /// Full width, 50 pt.
    case large
    /// Hugs its label (14 pt side padding): 36 visible, 44 hit (Accept, Decline, Try again).
    case small
}

/// A button with enabled, pressed, disabled and loading states (A8.11, A5.2,
/// A5.3). Labels are verb-first, sentence case; the loading label is the
/// progressive verb ("Confirming…"). While loading the button keeps its
/// colours, size and position, ignores taps (never submits twice) and its
/// accessibility label becomes the progressive verb.
///
///     MoolaButton("Sign in", loadingTitle: "Signing in…", isLoading: store.isSigningIn) { … }
///     MoolaButton("Confirm with Face ID", systemImage: "faceid") { … }
public struct MoolaButton: View {
    let title: String
    let loadingTitle: String?
    let systemImage: String?
    let kind: MoolaButtonKind
    let size: MoolaButtonSize
    let isLoading: Bool
    let keepsLabelWhileLoading: Bool
    let fillsWidth: Bool?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - systemImage: optional leading symbol (18 pt Medium, 8 pt before the
    ///     label); dropped at accessibility sizes (the words name the method).
    ///   - keepsLabelWhileLoading: the lock screen's exception (ruling 21): the
    ///     label stays and only the leading symbol becomes the spinner.
    ///   - fillsWidth: overrides the size's width rule (two `.small` buttons of
    ///     equal width side by side pass `true`, A8.9).
    public init(
        _ title: String,
        kind: MoolaButtonKind = .primary,
        size: MoolaButtonSize = .large,
        systemImage: String? = nil,
        loadingTitle: String? = nil,
        isLoading: Bool = false,
        keepsLabelWhileLoading: Bool = false,
        fillsWidth: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.size = size
        self.systemImage = systemImage
        self.loadingTitle = loadingTitle
        self.isLoading = isLoading
        self.keepsLabelWhileLoading = keepsLabelWhileLoading
        self.fillsWidth = fillsWidth
        self.action = action
    }

    public var body: some View {
        Button(role: kind == .destructive ? .destructive : nil) {
            guard !isLoading else { return }
            action()
        } label: {
            label
        }
        .buttonStyle(MoolaButtonStyle(kind: kind, fullWidth: fillsWidth ?? (size == .large), small: size == .small))
        .allowsHitTesting(!isLoading)
        .accessibilityLabel(isLoading && !keepsLabelWhileLoading ? (loadingTitle ?? title) : title)
    }

    private var spinnerColor: Color {
        switch kind {
        case .primary: Palette.ctaForeground
        case .secondary, .plain: Palette.textPrimary
        case .destructive: Palette.redText
        }
    }

    @ViewBuilder
    private var label: some View {
        if keepsLabelWhileLoading {
            Label {
                Text(title)
            } icon: {
                if isLoading {
                    ProgressView().tint(spinnerColor)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
            }
        } else {
            // The label and the progress row share one frame, so the button never
            // changes size while it loads: the frame is laid out from hidden
            // copies and only the current one is drawn; they cross-fade with
            // `Motion.swap` (A5.3). Exactly one text is drawn at rest, so the
            // Button stays one element named by its label, as in v1: a second,
            // invisible text drawn at opacity 0 was exposed to UI tests and the
            // accessibility audit as a static text of its own (measured on iOS
            // 26.5; accessibility modifiers did not remove it).
            //
            // Only a button that can load reserves its progress row, and the
            // row is never taller than its verb: the spinner sits beside it in
            // a fixed 20 pt slot at every size. (A reserved spinner-over-verb
            // row made every AX5 button about 64 pt taller than its label, so
            // pinned bars covered forms.) A `.small` button hugs its label (14
            // pt each side, A8.11), so while loading it draws the spinner alone,
            // centred; its accessibility label is still the progressive verb.
            ZStack {
                idleLabel.hidden()
                if size == .large, loadingTitle != nil {
                    progressRow.hidden()
                }
                if isLoading {
                    Group {
                        if size == .small {
                            spinner
                        } else {
                            progressRow
                        }
                    }
                    .transition(.opacity)
                } else {
                    idleLabel
                        .transition(.opacity)
                }
            }
            .animation(Motion.animation(Motion.swap, reduceMotion: reduceMotion), value: isLoading)
        }
    }

    private var spinner: some View {
        ProgressView()
            .tint(spinnerColor)
            .frame(width: 20, height: 20)
    }

    private var progressRow: some View {
        HStack(spacing: Spacing.space2) {
            spinner
            Text(loadingTitle ?? title)
        }
    }

    @ViewBuilder
    private var idleLabel: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

/// The style behind `MoolaButton`, usable on any `Button` (A-R `MoolaButtonStyle`).
/// Primary: ink fill, pressed `ctaPressed`. Secondary and destructive: `fill`,
/// pressed `fillPressed`. Plain: no container, pressed opacity 0.5. The pressed
/// colour shows with no animation; only the 0.97 scale eases in (`Motion.pressIn`)
/// and everything eases back with `Motion.release`; no scale under Reduce Motion.
public struct MoolaButtonStyle: ButtonStyle {
    public var kind: MoolaButtonKind
    public var fullWidth: Bool
    public var small: Bool

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
        @Environment(\.multilineTextAlignment) private var inheritedAlignment

        var body: some View {
            let pressed = configuration.isPressed && isEnabled
            let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            let accessibilitySize = dynamicTypeSize.isAccessibilitySize
            configuration.label
                // A8.11: the leading symbol is dropped at accessibility sizes.
                .labelStyle(MoolaButtonLabelStyle(showsIcon: !accessibilitySize))
                .textStyle(.headline)
                // Labels never truncate: 2 lines at the default sizes, unlimited at AX sizes.
                .lineLimit(accessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                // Filled and tonal labels are centred; a plain link wraps to
                // its placement (the caller's alignment, e.g. trailing for
                // "Forgot password?", leading for "Resend code").
                .multilineTextAlignment(kind == .plain ? inheritedAlignment : .center)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .plain ? 0 : (small ? 14 : 20))
                .padding(.vertical, kind == .plain || small ? 0 : (accessibilitySize ? 12 : 0))
                .frame(maxWidth: fullWidth && kind != .plain ? .infinity : nil)
                .frame(minHeight: kind == .plain ? Size.minimumTapTarget : (small ? Size.smallButtonHeight : Size.buttonHeight))
                .background(background(pressed: pressed), in: shape)
                .opacity(kind == .plain && pressed ? 0.5 : 1)
                // Colour and opacity: instant on touch-down, eased on release (A5.2).
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .overlay {
                    if kind == .secondary || kind == .destructive, contrast == .increased {
                        shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline)
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
    public var showsIcon: Bool

    public init(showsIcon: Bool = true) {
        self.showsIcon = showsIcon
    }

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

/// An inline link: `headline` ink, Medium, no underline, no colour, pressed
/// opacity 0.5, 44 pt hit height ("See all", "Edit amount", "Forgot password?",
/// "Resend code"). Home's "Cash out" and "History" pass a leading symbol
/// (ruling 53: 15 pt Medium, 6 pt before the label; the accessibility label
/// stays the title). Disabled: `textTertiary`. When the label wraps (at
/// accessibility sizes) its lines align to the link's placement: `alignment`
/// `.trailing` for a trailing link ("Forgot password?"), `.leading` for one at
/// the leading edge ("Use a backup code"), `.center` (default) for a centred one.
public struct TextLinkButton: View {
    let title: String
    let systemImage: String?
    let alignment: TextAlignment
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 15

    public init(_ title: String, systemImage: String? = nil, alignment: TextAlignment = .center, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.alignment = alignment
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            if let systemImage {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage)
                        .font(.system(size: symbolSize, weight: .medium))
                }
                .labelStyle(LinkLabelStyle())
            } else {
                Text(title)
            }
        }
        .buttonStyle(MoolaButtonStyle(kind: .plain, fullWidth: false))
        .multilineTextAlignment(alignment)
    }

    private struct LinkLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.accessibilityHidden(true)
                configuration.title
            }
        }
    }
}

/// "See all" in a `SectionHeader`: `headline` ink, pressed opacity 0.5. Its
/// 44 pt hit region adds NO layout height: the hit area is grown by 12.6 pt
/// above and below and 8 pt each side with padding that negative padding
/// cancels, so the header's frame is the title line (A8.24).
public struct SectionLinkStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .opacity(pressed ? 0.5 : 1)
                // Instant on touch-down, eased back on release, as every other
                // link (A5.2).
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .padding(.vertical, 12.6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .padding(.vertical, -12.6)
                .padding(.horizontal, -8)
        }
    }
}

#Preview("Buttons") {
    VStack(spacing: 12) {
        MoolaButton("Move to goal") {}
        MoolaButton("Confirm with Face ID", systemImage: "faceid") {}
        MoolaButton("Sign in", loadingTitle: "Signing in\u{2026}", isLoading: true) {}
        MoolaButton("Review") {}.disabled(true)
        MoolaButton("Move to balance", kind: .secondary) {}
        MoolaButton("Delete goal", kind: .destructive) {}
        HStack {
            MoolaButton("Accept", size: .small) {}
            MoolaButton("Decline", kind: .secondary, size: .small) {}
        }
        HStack(spacing: 24) {
            TextLinkButton("Cash out", systemImage: "arrow.up.right") {}
            TextLinkButton("History", systemImage: "list.bullet.rectangle.portrait") {}
        }
        TextLinkButton("See all") {}
    }
    .padding()
    .moolaCanvas()
}

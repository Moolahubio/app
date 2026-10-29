import SwiftUI

/// Spacing (DESIGN.md v2 A3.2). v1's scale names and values are kept; the
/// roles change: 16 pt screen gutter, 20 pt sheet inset, 52 pt between
/// sections, 16 pt from a heading to its first content.
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
    public static let space12: CGFloat = 48
    public static let space16: CGFloat = 64

    // Roles (v2)
    /// Side margin of every full screen (v1: 20).
    public static let screenGutter: CGFloat = 16
    /// Side inset inside sheets (v1: 24).
    public static let sheetPadding: CGFloat = 20
    /// From the bottom of one section's last element to the next section heading's frame.
    public static let sectionGap: CGFloat = 52
    /// Section heading frame to its first content (lists subtract their own top padding).
    public static let headingToContent: CGFloat = 16
    /// Horizontal and vertical gap in every 2-column grid.
    public static let gridGap: CGFloat = 12
    /// Field label frame to the field's top.
    public static let labelToField: CGFloat = 12
    /// Field bottom to the next label's frame.
    public static let fieldToNextLabel: CGFloat = 20
}

/// Corner radii, all `.continuous` (A3.4). At most three content radii per
/// screen besides capsules and emoji tiles; a nested shape uses outer − inset,
/// never below 6.
public enum Radius {
    /// The floor for any shape nested inside a tile or card (v1 8).
    public static let small: CGFloat = 6
    /// Buttons, text fields, banners, the inset selection pill (v1 12).
    public static let medium: CGFloat = 10
    /// Tiles and outlined cards (v1 16).
    public static let large: CGFloat = 14
    /// Tiles and outlined cards (v1 20).
    public static let card: CGFloat = 14
    /// Alias of `medium`: every control.
    public static let control: CGFloat = 10
}

/// Control and row sizes (A3.5). A-R's `Size.button`, `Size.smallButton` and
/// `Size.field` ship as `buttonHeight`, `smallButtonHeight` and `textFieldHeight` (U4).
public enum Size {
    public static let minimumTapTarget: CGFloat = 44
    /// Primary, secondary and destructive buttons (v1 56).
    public static let buttonHeight: CGFloat = 50
    /// Small buttons and chips: 36 visible, 44 hit.
    public static let smallButtonHeight: CGFloat = 36
    public static let textFieldHeight: CGFloat = 52
    /// Member-row avatars, the identity media column (A8.13; v1 40).
    public static let avatar: CGFloat = 52
    public static let hairline: CGFloat = 1
    /// A focused or invalid field's border (A3.6, A8.26).
    public static let focusBorder: CGFloat = 1.5
    /// A focused field's border with Increase Contrast (A3.6, A8.26).
    public static let focusBorderIncreasedContrast: CGFloat = 2
    /// A selected choice's ring (A3.6, A8.29) and the emoji picker's selection.
    public static let selectionRing: CGFloat = 2
    /// A goal row's bottom padding under its 4 pt bar (A3.5: 16 + 53.3 + 16.7 = 86).
    public static let goalRowBottomPadding: CGFloat = 16.7
}

/// Motion tokens (A5.1). Every custom animation uses one; every one has a
/// Reduce Motion form. Springs never overshoot (bounce 0).
public enum Motion {
    /// Press-in SCALE only. Colour and opacity change on touch-down with no
    /// animation, so the press shows in the first frame (A5.2).
    public static let pressIn = Animation.easeOut(duration: 0.06)
    /// Release of colour, opacity and scale: 90 % back at about 155 ms.
    public static let release = Animation.spring(duration: 0.25, bounce: 0)
    /// Banners and toasts appearing, chip selection, layout changes.
    public static let standard = Animation.spring(duration: 0.3, bounce: 0)
    /// `numericText` rolls and progress width changes.
    public static let figure = Animation.spring(duration: 0.35, bounce: 0)
    /// Toast out, keypad press circle fading.
    public static let exit = Animation.easeIn(duration: 0.2)
    /// The label and spinner swap inside a loading button (A5.3).
    public static let swap = Animation.easeOut(duration: 0.15)
    /// Replaces every token above under Reduce Motion (A-R calls it `Motion.reduced`).
    public static let reducedCrossfade = Animation.easeInOut(duration: 0.2)
    /// Reduce Motion release: colour only, no scale.
    public static let reducedRelease = Animation.easeOut(duration: 0.15)

    /// `animation`, or the Reduce Motion crossfade (`Motion.reduced` in A5.1).
    /// Every view that animates reads `accessibilityReduceMotion` and passes
    /// it here: `.animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: …)`.
    public static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedCrossfade : animation
    }
}

// MARK: - Press styles (A5.2)

/// Tappable tiles and outlined cards: the button style draws the fill
/// (`restingFill`, pressed `fillPressed` at once, back with `Motion.release`)
/// and a 0.98 scale (none under Reduce Motion). Pass `Palette.surface` for
/// tiles and `Palette.canvas` for outlined cards; the content takes
/// `.tileStyle(fill: false)` or `.outlinedCardStyle(fill: false)` (ruling 31).
public struct PressableCardButtonStyle: ButtonStyle {
    public var restingFill: Color
    public var cornerRadius: CGFloat

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
                .background(
                    pressed ? Palette.fillPressed : restingFill,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .animation(pressed ? Motion.pressIn : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
        }
    }
}

/// Full-width list rows (settings, choose-a-goal and activity rows, `PickerField`):
/// the row background turns `fillPressed` at once while held and fades back
/// with `Motion.release`; no scale (A5.2).
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
                .environment(\.rowIsPressed, pressed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(pressed ? Palette.fillPressed : Color.clear)
                .animation(pressed ? nil : (reduceMotion ? Motion.reducedRelease : Motion.release), value: pressed)
        }
    }
}

struct RowIsPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the `RowButtonStyle` row around this view is pressed: its
    /// `fillPressed` is the same grey as `progressTrack`, so a progress bar
    /// in the row draws its track in `canvas` meanwhile (a goal row's bar
    /// would otherwise vanish while held), and the inset selection pill hides.
    var rowIsPressed: Bool {
        get { self[RowIsPressedKey.self] }
        set { self[RowIsPressedKey.self] = newValue }
    }
}

// MARK: - Containers (A3.7, A8.5): only for tappable or decision objects

/// Things you own and open: `surface`, radius 14, padding 16, no border
/// (Increase Contrast: 1 pt `cardBorder`).
struct TileStyle: ViewModifier {
    var fill = true
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(Spacing.space4)
            .background(fill ? Palette.surface : Color.clear, in: shape)
            .overlay {
                if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
            }
    }
}

/// Objects that ask for a decision or belong to other people: `canvas`, a
/// 1 pt `cardBorder`, radius 14, padding 16.
struct OutlinedCardStyle: ViewModifier {
    var fill = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(Spacing.space4)
            .background(fill ? Palette.canvas : Color.clear, in: shape)
            .overlay { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
    }
}

/// The inset selection pill (A8.13, A8.21; premium bar P9, DS-3):
/// `selectionPill`, radius 10, inset 8 pt from the row's sides and 2 pt inside
/// its top and bottom, behind the row's content (which stays on the 16 pt gutter).
/// Increase Contrast adds a 1 pt `cardBorder`. When `isOn` changes the pill
/// fades with `Motion.standard` (the Reduce Motion crossfade under Reduce Motion).
/// While a `RowButtonStyle` row around it is held, the pill hides at once, so
/// the press reads as the one full-width `fillPressed` band, and it comes back
/// with the band's `Motion.release`.
struct InsetSelectionPill: ViewModifier {
    let isOn: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rowIsPressed) private var rowIsPressed

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
            shape.fill(Palette.selectionPill)
                .overlay {
                    if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
                }
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, 2)
                .opacity(isOn && !rowIsPressed ? 1 : 0)
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: isOn)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The one selection shape in the app (premium bar P9): an inset
    /// `selectionPill` behind a full-width row, 8 pt from its sides and 2 pt
    /// inside its top and bottom; Increase Contrast adds a 1 pt `cardBorder`. The
    /// signed-in user's member and timeline rows and the selected settings
    /// option draw it. Never the only sign of selection: the row also carries
    /// a word, "(you)" or a checkmark, and `.isSelected` where it is a choice.
    public func insetSelectionPill(_ isOn: Bool) -> some View {
        modifier(InsetSelectionPill(isOn: isOn))
    }

    /// A tile: `surface`, radius 14, padding 16. On a tile that is itself a
    /// button pass `fill: false`: `PressableCardButtonStyle` draws the fill.
    public func tileStyle(fill: Bool = true) -> some View {
        modifier(TileStyle(fill: fill))
    }

    /// An outlined card: `canvas` + 1 pt `cardBorder`, radius 14, padding 16.
    /// On a card that is itself a button pass `fill: false` and
    /// `PressableCardButtonStyle(restingFill: Palette.canvas)`.
    public func outlinedCardStyle(fill: Bool = true) -> some View {
        modifier(OutlinedCardStyle(fill: fill))
    }

    /// The page ground of every full screen (`canvas`). Never inside an iOS 26 sheet.
    public func moolaCanvas() -> some View {
        background(Palette.canvas.ignoresSafeArea())
    }
}

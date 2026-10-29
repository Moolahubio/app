import SwiftUI
import UIKit

/// The iOS 17/18 ground behind a pinned bar (A8.30): `canvas` on screens,
/// `sheetCanvas` in sheets. On iOS 26 the bar sits on the system scroll edge.
public enum PinnedBarGround: Sendable {
    case canvas, sheet
}

/// Bottom padding of a pinned bar (A3.2, A8.30, ruling 19, B1.0.3).
public enum PinnedBarMetrics {
    /// 8 pt above the bottom safe area; 0 when the bar ends with a 44 pt footer
    /// row (Sign in, Sign up, the lock screen's "Sign out"); 16 wherever the
    /// bottom inset is 0 (home-button iPhones, ruling 19), footer row or not
    /// (B1.3 at 375 × 667: "Sign out" 607 to 651 on a 667 pt screen).
    public static func bottomPadding(bottomSafeArea: CGFloat, endsWithFooterRow: Bool) -> CGFloat {
        if bottomSafeArea == 0 { return Spacing.space4 }
        return endsWithFooterRow ? 0 : Spacing.space2
    }

    /// An amount step's bottom edge (A8.12, A8.30): `.soft` where the keypad
    /// fits above the bar, `.hard` on home-button iPhones (bottom inset 0,
    /// 375 × 667), where its last rows rest under the bar and a soft edge let
    /// half-hidden digits show above and below the button.
    @MainActor
    public static var amountStepHardEdge: Bool {
        windowBottomSafeArea == 0
    }

    /// The key window's bottom safe-area inset (0 on home-button iPhones), for
    /// `bottomPadding(bottomSafeArea:endsWithFooterRow:)`.
    @MainActor
    public static var windowBottomSafeArea: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.safeAreaInsets.bottom ?? 0
    }
}

/// The one pinned bottom bar for every screen and sheet (A4.4, A8.30). iOS 26:
/// `safeAreaBar(edge: .bottom)` with the bottom scroll edge `.soft`, or `.hard`
/// when text sits under the button (a reason slot or a footer row); iOS 17/18:
/// `safeAreaInset(edge: .bottom)` on an opaque ground. The button is opaque
/// content, never glass. A bar holds at most, in order: an ErrorBanner, the
/// main button, its reserved reason slot, one secondary, one plain link. At
/// accessibility sizes the caller puts only the main button in the bar; the
/// rest moves into the scroll content, keeping identifiers and order.
///
///     ScrollView { … }
///         .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet, hardEdge: true) {
///             VStack(spacing: Spacing.space2) {
///                 MoolaButton("Save changes") { … }.disabled(!hasChanges)
///                 DisabledReasonLine(text: "Change your name or username to save.", isShown: !hasChanges)
///             }
///         })
public struct PinnedActionBar<Bar: View>: ViewModifier {
    let inset: CGFloat
    let ground: PinnedBarGround
    let bottomPadding: CGFloat?
    let hardEdge: Bool
    let keyboardMargin: Bool
    let bar: () -> Bar

    /// The bar's height and whether the software keyboard is up (iOS 26 path).
    @State private var barHeight: CGFloat = 0
    @State private var keyboardIsUp = false

    /// - Parameters:
    ///   - inset: 16 on screens (`Spacing.screenGutter`), 20 in sheets (`Spacing.sheetPadding`).
    ///   - bottomPadding: `PinnedBarMetrics.bottomPadding(bottomSafeArea:endsWithFooterRow:)`;
    ///     nil (the default) is that value for a bar without a footer row: 8 pt
    ///     above the bottom safe area, 16 where the inset is 0 (ruling 19).
    ///   - hardEdge: true when text sits under the button.
    ///   - keyboardMargin: true on a form whose fields must clear the bar
    ///     while the keyboard is up (Sign in, Sign up, Reset password,
    ///     Profile): see the iOS 26 path in `body`. It acts on the `.canvas`
    ///     ground only; a sheet's insets already count the bar.
    public init(
        inset: CGFloat = Spacing.screenGutter,
        ground: PinnedBarGround = .canvas,
        bottomPadding: CGFloat? = nil,
        hardEdge: Bool = false,
        keyboardMargin: Bool = false,
        @ViewBuilder bar: @escaping () -> Bar
    ) {
        self.inset = inset
        self.ground = ground
        self.bottomPadding = bottomPadding
        self.hardEdge = hardEdge
        self.keyboardMargin = keyboardMargin
        self.bar = bar
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // While the keyboard is up, the bar rides on it, but on iOS 26.5
            // the scroll view's insets count only the keyboard, not the bar:
            // a field just above the keyboard sat under the bar and the
            // content could not scroll it out (Sign in's Password, 17 pt
            // under the bar after an email error; on a 375 × 667 iPhone the
            // whole field). With `keyboardMargin`, the bar's height is added
            // as a bottom content margin meanwhile, so the screen's own
            // scroll-to-focus can clear the bar. Opt-in: on other forms the
            // late inset change moved a control under a tap. Screens only: in
            // a sheet the insets already count the bar, and the margin made
            // a `scrollTo(_:anchor: .bottom)` land one bar height too high
            // (the step-up sheet at AX5, 2026-10-29: the refusal ended 167 pt
            // above the bar's top with the margin, at its top without it).
            content
                .contentMargins(.bottom, keyboardMargin && keyboardIsUp && ground == .canvas ? barHeight : 0, for: .scrollContent)
                .scrollEdgeEffectStyle(hardEdge ? .hard : .soft, for: .bottom)
                .safeAreaBar(edge: .bottom) {
                    padded
                        // On a home-button iPhone (bottom inset 0) the iOS
                        // 26.5 hard edge still let the content under the bar
                        // show as blurred shapes above and below the button
                        // (an amount step's last keypad rows): there the bar
                        // gets the opaque ground it has on iOS 17 and 18.
                        .background {
                            if hardEdge && PinnedBarMetrics.windowBottomSafeArea == 0 {
                                groundColor
                            }
                        }
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barHeight = $0 }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    keyboardIsUp = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardIsUp = false
                }
        } else {
            content
                .safeAreaInset(edge: .bottom) {
                    padded.background(groundColor)
                }
        }
    }

    private var groundColor: Color {
        ground == .sheet ? Palette.sheetCanvas : Palette.canvas
    }

    private var padded: some View {
        bar()
            .padding(.horizontal, inset)
            .padding(.top, Spacing.space3)
            .padding(.bottom, bottomPadding ?? PinnedBarMetrics.bottomPadding(
                bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: false
            ))
    }
}

/// A disabled main action's reason (A9.9): `footnote`, centred, 8 pt under
/// the button (the caller's spacing). The slot is RESERVED: it keeps its
/// height while the action is enabled and only fades its text with
/// `Motion.standard`, so the button never moves under the thumb when the form
/// becomes valid. `textSecondary`, or `redText` for a refusal ("You need
/// {amount} available to pay in. Add money first."). While the action is
/// disabled, pass the same text to the button's `accessibilityHint`.
///
/// The slot is a `.hidden()` copy of the text and the visible line is drawn
/// over it only while shown: on iOS 26.5 a `Text` kept at opacity 0 is still
/// exposed to UI tests and the accessibility audit as a static text, even
/// with `.accessibilityHidden(true)` (README §5).
public struct DisabledReasonLine: View {
    let text: String
    let isShown: Bool
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String, isShown: Bool = true, color: Color = Palette.textSecondary) {
        self.text = text
        self.isShown = isShown
        self.color = color
    }

    public var body: some View {
        line
            .hidden()
            .overlay {
                if isShown {
                    line.transition(.opacity)
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: isShown)
    }

    private var line: some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

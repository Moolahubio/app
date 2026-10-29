import SwiftUI

// Chrome (DESIGN.md v2 A4): Liquid Glass comes only from system components
// (TabView, navigation and toolbar items, sheets, dialogs). Nothing here draws
// glass or a material; these modifiers configure the system chrome and the
// opaque grounds next to it.

/// The tab bar never minimizes (iOS 26 `tabBarMinimizeBehavior(.never)`; the
/// tests tap every tab button). Apply to the `TabView` (A4.2).
public struct TabBarNeverMinimizes: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.never)
        } else {
            content
        }
    }
}

/// Every sheet (A4.4): detents, the grabber, the ink tint (so a sheet
/// presented from inside the jade-tinted `TabView` never inherits the tab
/// tint), and on iOS 17/18 the opaque `sheetCanvas`. On iOS 26 nothing is
/// painted, so the system sheet glass shows; content inside paints no
/// background (no `.moolaCanvas()`), and tokens resolve to the dark elevated
/// set by themselves.
///
///     .modifier(SheetChrome(detents: [.large]))   // or .sheetChrome([.large])
public struct SheetChrome: ViewModifier {
    let detents: Set<PresentationDetent>

    public init(detents: Set<PresentationDetent>) {
        self.detents = detents
    }

    public func body(content: Content) -> some View {
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

extension View {
    /// `SheetChrome(detents:)` (A4.4): money moves and create flows `[.large]`;
    /// About your balance, How groups work, Invite people `[.medium, .large]`;
    /// Cash out and the app lock offer `[.medium]`.
    public func sheetChrome(_ detents: Set<PresentationDetent>) -> some View {
        modifier(SheetChrome(detents: detents))
    }
}

/// Close for sheets (A4.4, ruling 1): iOS 26 `Button(role: .close)`, iOS 17/18
/// `Button("Close", systemImage: "xmark")`. The identifier is the caller's
/// (default "Close"; Savings passes "savings.sheet.close", Add test money
/// "home.addMoney.close"). Place it in `ToolbarItem(placement: .cancellationAction)`
/// on a sheet's first step and `ToolbarItem(placement: .topBarTrailing)` on a
/// pushed step; never `.confirmationAction` (iOS 26.5 draws that as a filled
/// prominent circle, so Close would look like the confirm action).
public struct SheetCloseButton: View {
    let identifier: String
    let action: () -> Void

    public init(identifier: String = "Close", action: @escaping () -> Void) {
        self.identifier = identifier
        self.action = action
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityIdentifier(identifier)
        } else {
            Button("Close", systemImage: "xmark", action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The hard top scroll edge on iOS 26 (A4.3): Goal detail and Group detail,
/// whose identity band runs up behind the bar and whose content holds a
/// full-width ink primary. Gated at the View level (gotcha G1).
public struct HardTopScrollEdge: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

/// The identity band of the person's own goal or group page (A8.32): full
/// bleed, from the screen's top edge (behind the status bar and the inline
/// bar) to 24 pt below its last line; content at the 16 pt gutter. Goal
/// detail passes the goal's A1.5 tint (`GoalTint.color(forAPIKey:)`), Group
/// detail `Palette.headerBand`. Opaque content, never glass. Use it with
/// `IdentityBandScreen` on the scroll view and `BelowIdentityBand` on the
/// content after it.
public struct IdentityBand<Content: View>: View {
    let tint: Color
    let content: Content

    public init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
    }
}

/// On the screen's `ScrollView`: its ground is the band tint and, on iOS 26,
/// the top scroll edge is `.hard`, so at rest the band runs behind the bar
/// and, scrolled, the bar region keeps the item's colour (A4.3, A8.32).
public struct IdentityBandScreen: ViewModifier {
    let tint: Color

    public init(tint: Color) {
        self.tint = tint
    }

    public func body(content: Content) -> some View {
        content
            .modifier(HardTopScrollEdge())
            .background(tint)
    }
}

/// On the content after the band: `canvas`, extended 2,000 pt below the
/// content so a bottom overscroll never shows the band tint (A8.32).
public struct BelowIdentityBand: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.background(alignment: .top) {
            Palette.canvas.padding(.bottom, -2000)
        }
    }
}

/// Home's greeting band (A8.1): a full-bleed `headerBand` band; the greeting in
/// `greeting` (21 Medium) at the gutter, 16 pt below the top safe area; an
/// optional second line (the freshness line, `subheadline` `textSecondary`)
/// 4 pt below; the band ends 20 pt below the last line. The greeting is a
/// header and carries the caller's identifier (Home: "home.greeting"). Put the
/// scroll view in `GreetingHeaderChrome` so the status-bar strip and the
/// pull-to-refresh gap stay band coloured.
public struct GreetingHeader: View {
    let greeting: String
    let detail: String?
    let identifier: String?

    /// - Parameters:
    ///   - greeting: "Good to see you, {first}" ("Good to see you" without a name).
    ///   - detail: "Updated 5 min ago" when Home shows a cached snapshot.
    public init(_ greeting: String, detail: String? = nil, identifier: String? = nil) {
        self.greeting = greeting
        self.detail = detail
        self.identifier = identifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(greeting)
                .textStyle(.greeting)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .modifier(OptionalIdentifier(identifier: identifier))
            if let detail {
                Text(detail)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Spacing.space4)
        .padding(.bottom, Spacing.space5)
        .padding(.horizontal, Spacing.screenGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerBand)
    }
}

/// On Home's `ScrollView` (A8.1 "At the top edge", ruling 15): the top safe
/// area is a fixed `headerBand` strip above the scrolling content, and the
/// scroll view's backdrop is `headerBand` at the top (400 pt) and `canvas`
/// below, so pull to refresh never opens a white gap above the band. Hides
/// the navigation bar (Home has none).
///
/// The scroll content paints its own grounds: `GreetingHeader` paints the
/// band, and everything after it must sit in a container with
/// `.background(Palette.canvas)`; otherwise the band-coloured backdrop shows
/// through behind the content's top 400 pt when it scrolls.
///
///     ScrollView {
///         VStack(spacing: 0) {
///             GreetingHeader("Good to see you, Ama", identifier: "home.greeting")
///             VStack { … }.background(Palette.canvas)
///         }
///     }
///     .modifier(GreetingHeaderChrome())
public struct GreetingHeaderChrome: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background {
                VStack(spacing: 0) {
                    Palette.headerBand.frame(height: 400)
                    Palette.canvas
                }
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(Palette.headerBand)
            }
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Applies an accessibility identifier only when one is given.
struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

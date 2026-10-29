import Auth
import DesignSystem
import SwiftUI

/// Full-screen lock (DESIGN.md v2 B1.3, A9.11). The 72 pt mark sits exactly
/// where the launch screen and the privacy cover put it (centred in the safe
/// area), so a locked cold launch changes nothing but the title and buttons
/// appearing. Title "MoolaHub is locked" (`titleLarge`) 16 pt below the mark;
/// a pinned primary "Unlock with Face ID" with a plain "Sign out" under it.
/// Prompts once automatically, then on tap; the button keeps its label while
/// the prompt runs (ruling 21) and swaps only its symbol for the spinner.
struct LockScreenView: View {
    let services: AppServices
    @State private var confirmsSignOut = false
    @State private var didAutoPrompt = false
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let markSize: CGFloat = 72

    var body: some View {
        let markCentre = Self.markSize / 2
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes the content above the bar scrolls.
                ScrollView {
                    VStack(spacing: Spacing.space4) {
                        MoolaMark(size: Self.markSize)
                        title
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.vertical, Spacing.space8)
                }
                .modifier(PinnedActionBar(
                    inset: Spacing.screenGutter,
                    ground: .canvas,
                    bottomPadding: PinnedBarMetrics.bottomPadding(bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: true),
                    hardEdge: true
                ) { actions })
            } else {
                ZStack {
                    // The mark's centre is the safe area's centre (B1.1, B1.2, B1.3);
                    // the title hangs 16 pt below it without moving it.
                    VStack(spacing: Spacing.space4) {
                        MoolaMark(size: Self.markSize)
                        title
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    .alignmentGuide(VerticalAlignment.center) { $0[.top] + markCentre }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    actions
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.bottom, PinnedBarMetrics.bottomPadding(bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: true))
                }
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .onAppear { titleFocused = true }
        .task {
            guard !didAutoPrompt else { return }
            didAutoPrompt = true
            await services.appLock.unlock()
        }
    }

    private var title: some View {
        Text("MoolaHub is locked")
            .textStyle(.titleLarge)
            .foregroundStyle(Palette.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
    }

    private var actions: some View {
        let biometry = services.authenticator.biometryKind()
        return VStack(spacing: Spacing.space1) {
            MoolaButton(
                biometry.unlockTitle,
                systemImage: biometry.symbolName,
                isLoading: services.appLock.isAuthenticating,
                keepsLabelWhileLoading: true
            ) {
                Task { await services.appLock.unlock() }
            }
            TextLinkButton("Sign out") {
                confirmsSignOut = true
            }
            .frame(maxWidth: .infinity)
            // Attached to the link so the iOS 26 popover points at "Sign out".
            .confirmationDialog("Sign out of MoolaHub?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await services.session.signOut() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// One-time offer after the first sign-in on this device (B1.4): the decision
/// sheet pattern (A3.2), `SheetChrome([.medium])`. Title (`title1`) 32 pt below
/// the sheet's top edge, one sentence 8 pt below, then the primary "Turn on
/// Face ID" (leading biometry symbol) and a plain "Not now" at the bottom.
/// No decorative symbol (A7.1); the glyph works on the button.
struct AppLockOfferSheet: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var isEnabling = false
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        let biometry = services.authenticator.biometryKind()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Use \(biometry.name) to open MoolaHub")
                    .textStyle(.title1)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text("Your money stays private if someone picks up your phone.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.top, Spacing.space8)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            VStack(spacing: Spacing.space1) {
                MoolaButton(
                    "Turn on \(biometry.name)",
                    systemImage: biometry.symbolName,
                    loadingTitle: "Turning on\u{2026}",
                    isLoading: isEnabling
                ) {
                    isEnabling = true
                    Task {
                        await services.appLock.enable()
                        isEnabling = false
                        dismiss()
                    }
                }
                TextLinkButton("Not now") {
                    services.settings.appLockOffered = true
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .disabled(isEnabling)
            }
        })
        .sheetChrome([.medium])
        .interactiveDismissDisabled(isEnabling)
        .onAppear { titleFocused = true }
    }
}

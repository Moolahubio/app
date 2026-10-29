import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Welcome (DESIGN.md v2 B1.13). Static: no data, no balances, no sample goals.
/// The wordmark sits on the navigation-bar row; the headline and one sentence
/// are anchored low, just above the pinned "Create account" (ink) and
/// "Sign in" (tonal). Debug builds add the server row under "Sign in".
struct WelcomeView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if DEBUG
    @State private var serverHost = ServerEnvironment.displayHost(ServerEnvironment.currentBaseURL())
    @ScaledMetric(relativeTo: .callout) private var serverSymbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var serverSymbolSlot: CGFloat = 20
    #endif

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Centred on the navigation-bar row (62 to 106 on a 402 pt
                    // iPhone), where the back button sits on the next screen.
                    // The wordmark contains the mark, so it stands alone.
                    Wordmark(height: 36)
                        .padding(.top, Spacing.space1)

                    // The text block stays anchored to the pinned bar.
                    Spacer(minLength: Spacing.space6)

                    // Two Text views in one header element, not one Text with
                    // "\n": the accessibility audit reports a hard line break
                    // inside a Text as clipped.
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Save today.")
                        Text("Reach it together.")
                    }
                    .textStyle(.titleLarge)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)

                    Text("Personal goals and group savings in one place. Every move has a receipt.")
                        .textStyle(.body)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.space3)

                    #if DEBUG
                    if accessibilitySize {
                        // Accessibility sizes: the server row scrolls with the
                        // content so the pinned bar keeps only the two buttons.
                        serverRow
                            .padding(.top, Spacing.space6)
                    }
                    #endif
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.bottom, Spacing.space6)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .moolaCanvas()
        .toolbar(.hidden, for: .navigationBar)
        // No navigation bar here, so nothing stops content that scrolls up
        // (accessibility sizes) from running under the status bar: a
        // canvas-coloured strip covers the status bar area, as a hard top
        // edge would.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(Palette.canvas)
        }
        // Hard bottom edge (A8.30: text sits under the main button, here the
        // "Sign in" button and, in Debug builds, the server row). At
        // accessibility sizes the headline and body scroll under the two tall
        // buttons; a soft edge would show them in the gap between the buttons.
        .modifier(PinnedActionBar(
            inset: Spacing.screenGutter,
            ground: .canvas,
            bottomPadding: PinnedBarMetrics.bottomPadding(
                bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: showsServerRowInBar
            ),
            hardEdge: true
        ) {
            VStack(spacing: 0) {
                MoolaButton("Create account") { path.append(.createAccount) }
                MoolaButton("Sign in", kind: .secondary) { path.append(.signIn) }
                    .padding(.top, Spacing.space3)
                #if DEBUG
                if !accessibilitySize {
                    serverRow
                        .padding(.top, Spacing.space1)
                }
                #endif
            }
        })
        #if DEBUG
        .onAppear {
            serverHost = ServerEnvironment.displayHost(ServerEnvironment.currentBaseURL())
        }
        #endif
    }

    /// The Debug server row sits in the pinned bar (a footer row under
    /// "Sign in") except at accessibility sizes; Release has no row.
    private var showsServerRowInBar: Bool {
        #if DEBUG
        return !dynamicTypeSize.isAccessibilitySize
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Debug builds only: which server this build talks to, and a way to
    /// change it before signing in (needed on a physical iPhone). `server.rack`
    /// (16 pt `textSecondary` in a 20 pt slot), 8 pt, "Server: {host:port}"
    /// (`body` `textSecondary`, one line, middle truncation), 8 pt, "Change"
    /// → Developer settings. One combined element, as v1. At accessibility
    /// sizes it scrolls with the content: the text takes the full width (the
    /// symbol is dropped, as button symbols are, A8.11) and "Change" sits
    /// under it.
    private var serverRow: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = accessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Spacing.space2))
        return layout {
            HStack(spacing: Spacing.space2) {
                if !accessibilitySize {
                    Image(systemName: "server.rack")
                        .font(.system(size: serverSymbolSize, weight: .regular))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: serverSymbolSlot)
                        .accessibilityHidden(true)
                }
                Text("Server: \(serverHost)")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(accessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: accessibilitySize)
            }
            TextLinkButton("Change") {
                services.navigator.present(.developerSettings)
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    #endif
}

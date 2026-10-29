import APIClient
import DesignSystem
import Domain
import SwiftUI

// Building blocks shared by the signed-out screens (DESIGN.md v2 B1.0).
// Internal to FeatureAuth. Every visual piece comes from DesignSystem
// (MoolaTextField, CodeField, PickerField, MoolaButton, TextLinkButton,
// ErrorBanner, NoticeBanner, PinnedActionBar, DisabledReasonLine); these
// views only arrange them the way B1.0.2 and B1.0.3 lay out every auth screen.

/// The auth screen frame (B1.0.2): a scroll view under the system navigation
/// bar (inline, no title, the system back button only). The content has one
/// left edge at the 16 pt gutter, starts 12 pt below the bar (the `titleLarge`
/// title, P-11) and ends 24 pt above the pinned bar. It bounces only when it
/// overflows and a drag dismisses the keyboard. When `scrollToTopOn` becomes
/// non-nil (an error banner appeared) the screen scrolls to the top so the
/// banner is visible (B1.9).
///
/// `focusedField` is the id (`.id(_:)`) of the field that has keyboard focus.
/// Once the keyboard is up, the screen scrolls so the field sits in the
/// middle of the room above the keyboard, which keeps it whole above the
/// pinned bar riding on the keyboard: on iOS 26.5 neither the system's
/// keyboard avoidance nor a plain `scrollTo` counts the `safeAreaBar`, so a
/// field they call visible could sit under the bar (measured: Sign in's
/// Password 17 pt under it after an email error). `nextField` (the field Next
/// moves to) is the one centred when there is one, so the form never seems
/// to end at the focused field (on a 375 × 667 iPhone the bar would
/// otherwise cover Sign in's Password); the focused field, just above it,
/// always stays on screen. `layoutKey` is whatever moves the fields (field
/// errors appearing or going): when it changes, the scroll runs again.
struct AuthScreen<Content: View>: View {
    let scrollToTopOn: String?
    let focusedField: AnyHashable?
    let nextField: AnyHashable?
    let layoutKey: AnyHashable?
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        scrollToTopOn: String? = nil,
        focusedField: AnyHashable? = nil,
        nextField: AnyHashable? = nil,
        layoutKey: AnyHashable? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollToTopOn = scrollToTopOn
        self.focusedField = focusedField
        self.nextField = nextField
        self.layoutKey = layoutKey
        self.content = content()
    }

    private struct FocusScroll: Hashable {
        let field: AnyHashable?
        let next: AnyHashable?
        let layout: AnyHashable?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space3)
                .padding(.bottom, Spacing.space6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(AuthScrollAnchor.top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollToTopOn) { _, message in
                guard message != nil else { return }
                withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(AuthScrollAnchor.top, anchor: .top)
                }
            }
            .task(id: FocusScroll(field: focusedField, next: nextField, layout: layoutKey)) {
                guard let focusedField else { return }
                // After the keyboard, the bar and any field error have settled.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let animation = Motion.animation(Motion.standard, reduceMotion: reduceMotion)
                withAnimation(animation) { proxy.scrollTo(nextField ?? focusedField, anchor: .center) }
                if nextField != nil {
                    // Then the focused field, which moves only if the two did
                    // not fit together (it wins).
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    withAnimation(animation) { proxy.scrollTo(focusedField) }
                }
            }
        }
        .moolaCanvas()
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum AuthScrollAnchor: Hashable {
    case top
}

/// The title block of every auth screen (B1.0.2): the title in `titleLarge`
/// (34 Bold) `textPrimary`, a header; 8 pt; the subtitle in `body`
/// `textSecondary`. With `focusesOnAppear`, VoiceOver starts on the title
/// (B1.14, B1.17); the code screens leave focus to their field.
struct AuthTitle: View {
    let title: String
    let subtitle: Text
    let focusesOnAppear: Bool

    @AccessibilityFocusState private var titleFocused: Bool

    init(_ title: String, subtitle: String, focusesOnAppear: Bool = true) {
        self.init(title, subtitle: Text(subtitle), focusesOnAppear: focusesOnAppear)
    }

    init(_ title: String, subtitle: Text, focusesOnAppear: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.focusesOnAppear = focusesOnAppear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title)
                .textStyle(.titleLarge)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            subtitle
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            guard focusesOnAppear else { return }
            // After the push settles, so VoiceOver lands on the title.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            titleFocused = true
        }
    }
}

enum AuthText {
    /// An email inside a `body` sentence (B1.0.2, B1.16, B1.20): `headline`
    /// (16 Medium) in `textPrimary`, shown exactly as typed. Interpolate it into
    /// the sentence's `Text` (A2.5 rule 10); pass the font from
    /// `@ScaledTypeFont(.headline)` so it scales with Dynamic Type.
    static func email(_ address: String, font: Font) -> Text {
        Text(verbatim: address)
            .font(font)
            .foregroundStyle(Palette.textPrimary)
    }
}

/// The footer prompt row (B1.0.3): the prompt in `body` `textSecondary`, 4 pt,
/// a `TextLinkButton` (`headline` ink); same size, the weight carries the
/// link. Centred, 44 pt hit. Stacked when it doesn't fit on one line.
struct AuthFooterPrompt: View {
    let prompt: String
    let actionTitle: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.space1) {
                promptText
                link
            }
            VStack(spacing: 0) {
                promptText
                link
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var promptText: some View {
        Text(prompt)
            .textStyle(.body)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var link: some View {
        TextLinkButton(actionTitle, action: action)
            .accessibilityIdentifier(identifier)
    }
}

/// "Resend code" with the server's 30-second cooldown (B1.16, B1.20): a link
/// (`headline` ink, tabular digits; `textTertiary` while disabled) reading
/// "Resend in {s}s" until the cooldown ends, then "Resend code"; after a send,
/// "A new code is on its way." (`footnote` `textSecondary`, 4 pt below,
/// announced) and the countdown restarts. A failed send goes to the screen's
/// banner slot (`onFailure`, B1.9). The countdown changes without animation.
///
/// Every screen that shows it was reached right after the server emailed a
/// code, and the server won't send another within 30 seconds, so the
/// countdown starts when the screen appears rather than promising a code the
/// server would not send.
struct ResendCodeButton: View {
    /// Sends a new code. Throws the API error to show.
    let send: @MainActor () async throws(APIError) -> Void
    /// Runs after a new code went out (the screen clears its stale code error).
    let onSent: @MainActor () -> Void
    /// Runs with the message to show when a send failed.
    let onFailure: @MainActor (String) -> Void

    private static let cooldown: TimeInterval = 30

    @State private var cooldownEnd = Date().addingTimeInterval(ResendCodeButton.cooldown)
    @State private var remaining = Int(ResendCodeButton.cooldown)
    @State private var isSending = false
    @State private var didResend = false

    init(
        send: @escaping @MainActor () async throws(APIError) -> Void,
        onSent: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.send = send
        self.onSent = onSent
        self.onFailure = onFailure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Button {
                Task { await resend() }
            } label: {
                Text(remaining > 0 ? "Resend in \(remaining)s" : "Resend code")
                    .monospacedDigit()
            }
            .buttonStyle(MoolaButtonStyle(kind: .plain, fullWidth: false))
            .disabled(isDisabled)
            .accessibilityIdentifier("auth.resendCode")

            if didResend {
                Text("A new code is on its way.")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("auth.resendCode.sent")
            }
        }
        .task(id: cooldownEnd) {
            remaining = secondsLeft()
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                remaining = secondsLeft()
            }
        }
    }

    private var isDisabled: Bool { remaining > 0 || isSending }

    private func secondsLeft() -> Int {
        max(0, Int(cooldownEnd.timeIntervalSinceNow.rounded(.up)))
    }

    private func resend() async {
        guard !isDisabled else { return }
        isSending = true
        defer { isSending = false }
        do throws(APIError) {
            try await send()
            onSent()
            didResend = true
            cooldownEnd = Date().addingTimeInterval(Self.cooldown)
            remaining = secondsLeft()
            AccessibilityNotification.Announcement("A new code is on its way.").post()
        } catch {
            guard error != .cancelled else { return }
            onFailure(error.message(for: .action))
        }
    }
}

/// The calendar inside the date-of-birth popover (B1.15): the system graphical
/// `DatePicker`, labels hidden, 340 pt wide with 12 pt padding, selection in
/// the app's ink tint. Picking a day sets the value and keeps the popover
/// open; tapping outside closes it. The latest allowed day is yesterday.
struct DateOfBirthCalendar: View {
    @Binding var date: Date?

    @State private var draft: Date

    init(date: Binding<Date?>) {
        self._date = date
        self._draft = State(initialValue: date.wrappedValue ?? Self.latest)
    }

    /// Yesterday: the API only accepts a date in the past.
    static var latest: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    var body: some View {
        DatePicker("Date of birth", selection: $draft, in: ...Self.latest, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Palette.ctaBackground)
            .padding(Spacing.space3)
            .frame(width: 340)
            .onChange(of: draft) { _, newValue in
                date = newValue
            }
    }
}

extension String {
    /// The ASCII digits in this string, at most `limit` of them: what a code
    /// field keeps from typing or pasting.
    func codeDigits(limit: Int = 6) -> String {
        String(filter { ("0"..."9").contains($0) }.prefix(limit))
    }
}

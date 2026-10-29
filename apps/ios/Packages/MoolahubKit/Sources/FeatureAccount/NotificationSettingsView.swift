import APIClient
import Auth
import DesignSystem
import Domain
import Foundation
import SwiftUI

/// Notifications (DESIGN.md v2 B5.6): one of four levels, marked with an ink
/// checkmark, and the three category switches when the level is Custom.
/// Saves on every change, optimistically, one save at a time, and reverts
/// with an ErrorBanner when the save fails.
struct NotificationSettingsView: View {
    let services: AppServices

    /// The last state the server confirmed (load or successful save).
    @State private var preferences: RemoteResource<NotificationPreferences>
    /// What the screen shows while a save is in flight (optimistic).
    @State private var pending: NotificationPreferences?
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var saveFailures = 0
    /// Counts the level changes the person makes (the `.selection` haptic).
    @State private var levelChanges = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let saveFailedMessage = "We couldn't save that. Please try again."

    init(services: AppServices) {
        self.services = services
        let api = services.api
        _preferences = State(initialValue: RemoteResource {
            try await api.send(API.Notifications.preferences())
        })
    }

    private var shown: NotificationPreferences? { pending ?? preferences.value }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Choose how much you want to hear from MoolaHub.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.screenGutter)

                // The status block sits under the intro (A3.2).
                if saveFailed {
                    ErrorBanner(Self.saveFailedMessage)
                        .accessibilityIdentifier("account.notifications.error")
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.top, Spacing.space4)
                        .transition(.opacity)
                } else if let error = preferences.error, preferences.value != nil {
                    ErrorBanner(error.message(for: .screen)) {
                        Task { await preferences.refresh() }
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space4)
                    .transition(.opacity)
                }

                if case .failed(let error) = preferences.phase {
                    ErrorState(
                        title: "We couldn't load your notification settings",
                        message: error.message(for: .screen),
                        isRetrying: preferences.isLoading
                    ) {
                        Task { await preferences.refresh() }
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space6)
                } else {
                    levels
                        // The row's own 12 pt padding puts the first title 24 pt
                        // below the intro or banner (A3.2).
                        .padding(.top, Spacing.space3)
                    if let shown, shown.level == .custom {
                        categories(shown)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.top, AccountLayout.pushedTop)
            .padding(.bottom, Spacing.space6)
            .animation(standardAnimation, value: shown)
            .animation(standardAnimation, value: saveFailed)
        }
        .moolaCanvas()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: levelChanges)
        .sensoryFeedback(.error, trigger: saveFailures)
        .task { await preferences.load() }
    }

    // MARK: Levels (A8.21 selectable rows)

    /// The four levels are app copy, so they render at once while loading:
    /// no checkmark, not tappable, hidden from VoiceOver under one element
    /// "Loading your notification settings…". When the data lands only the
    /// checkmark fades in; nothing moves.
    private var levels: some View {
        let isLoading = shown == nil
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(NotificationPreferenceLevel.allCases, id: \.self) { level in
                SettingsSelectableRow(
                    title: Self.title(level),
                    subtitle: Self.detail(level),
                    badge: level == .everything ? "Recommended" : nil,
                    isSelected: shown?.level == level
                ) {
                    select(level)
                }
                .disabled(isSaving || isLoading)
                .accessibilityIdentifier("account.notifications.option.\(level.rawValue)")
            }
        }
        .accessibilityHidden(isLoading)
        .overlay {
            if isLoading {
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel("Loading your notification settings\u{2026}")
            }
        }
    }

    // MARK: Custom categories (A8.21 toggle rows)

    private func categories(_ shown: NotificationPreferences) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupDivider(textColumnX: Spacing.screenGutter)
            categoryToggle(
                "Money", detail: "Money added and sent, payouts and payment reminders.",
                id: "money", isOn: shown.categories.money
            ) { $0.money = $1 }
            categoryToggle(
                "Groups", detail: "Invitations, member activity and group updates.",
                id: "social", isOn: shown.categories.social
            ) { $0.social = $1 }
            categoryToggle(
                "Tips", detail: "Streaks, learning nudges and product news.",
                id: "engagement", isOn: shown.categories.engagement
            ) { $0.engagement = $1 }
        }
    }

    private func categoryToggle(
        _ title: String,
        detail: String,
        id: String,
        isOn: Bool,
        apply: @escaping (inout NotificationCategories, Bool) -> Void
    ) -> some View {
        SettingsToggleRow(title: title, subtitle: detail, isOn: Binding(get: { isOn }, set: { value in
            guard var next = shown else { return }
            next.preference = NotificationPreferenceLevel.custom.rawValue
            apply(&next.categories, value)
            save(next)
        }))
        .disabled(isSaving)
        .accessibilityIdentifier("account.notifications.category.\(id)")
    }

    // MARK: Saving

    private func select(_ level: NotificationPreferenceLevel) {
        guard var next = shown, next.level != level else { return }
        // Custom starts from the categories the person sees now.
        next.preference = level.rawValue
        levelChanges += 1
        save(next)
    }

    /// One save at a time (every row and switch ignores input while it's in
    /// flight), so the server always ends up with what the screen shows.
    private func save(_ optimistic: NotificationPreferences) {
        guard !isSaving, let level = optimistic.level else { return }
        pending = optimistic
        saveFailed = false
        isSaving = true
        let update = NotificationPreferencesUpdate(level: level, categories: level == .custom ? optimistic.categories : nil)
        Task {
            defer { isSaving = false }
            do throws(APIError) {
                let saved = try await services.api.send(Self.request(for: update))
                preferences.replace(with: saved)
                pending = nil
            } catch {
                // Back to what the server last confirmed.
                pending = nil
                guard error != .cancelled else { return }
                saveFailed = true
                saveFailures += 1
            }
        }
    }

    private static func request(for update: NotificationPreferencesUpdate) -> APIRequest<NotificationPreferences> {
        #if DEBUG
        // UI tests only (`-mh-account-reject-preference-saves`): send a value
        // the real server refuses (400 "Unknown notification preference."),
        // so the revert path runs against the live backend.
        if ProcessInfo.processInfo.arguments.contains("-mh-account-reject-preference-saves") {
            return .patch("/notifications/preferences", body: RejectedPreferenceBody())
        }
        #endif
        return API.Notifications.updatePreferences(update)
    }

    // MARK: Copy (B5.6)

    static func title(_ level: NotificationPreferenceLevel) -> String {
        switch level {
        case .everything: "Everything"
        case .essential: "Essential"
        case .minimal: "Minimal"
        case .custom: "Custom"
        }
    }

    static func detail(_ level: NotificationPreferenceLevel) -> String {
        switch level {
        case .everything: "All notifications: group activity, goal milestones, money added, reminders and tips."
        case .essential: "Important updates only, like payouts, pay-in due dates and account activity."
        case .minimal: "Only the most important account and money notifications."
        case .custom: "Choose exactly which kinds you want to hear about."
        }
    }
}

#if DEBUG
/// `{"preference":"qa-rejected"}`: see `NotificationSettingsView.request(for:)`.
private struct RejectedPreferenceBody: Encodable, Sendable {
    let preference = "qa-rejected"
}
#endif

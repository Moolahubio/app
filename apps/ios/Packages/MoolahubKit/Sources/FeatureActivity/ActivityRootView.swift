import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Activity tab root (DESIGN.md v2 B2.6): every move, newest first, grouped by
/// day under small grey day headers, in plain language. Each row opens the
/// move's receipt (B2.7). Placed inside the Activity tab's `NavigationStack`.
/// Keep this name and initializer: AppFeature calls it.
public struct ActivityRootView: View {
    /// `GET /activity?limit=100`; exactly this many back means there may be more.
    static let pageSize = 100

    private let services: AppServices
    @State private var activity: RemoteResource<[ActivityItem]>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(services: AppServices) {
        self.services = services
        let api = services.api
        _activity = State(initialValue: RemoteResource(cacheKey: .activity, cache: services.cache) {
            try await api.send(API.Activity.list(limit: ActivityRootView.pageSize))
        })
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.space8)
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: statusLines)
        }
        .accessibilityIdentifier("activity.scroll")
        .moolaCanvas()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await activity.refresh() }
        .task { await activity.load() }
        // A sheet that closed may have moved money (B2.9 item 1).
        .onChange(of: services.navigator.appSheetDismissals) { _, _ in
            refresh()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let items = activity.value {
            loaded(items)
        } else if let error = activity.error {
            if error != .sessionExpired && error != .cancelled {
                // Never loaded (D4): no list, no amounts.
                ErrorState(
                    title: "We couldn't load your activity",
                    message: error.message(for: .screen),
                    isRetrying: activity.isLoading
                ) {
                    refresh()
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            }
            // Session expired: the root swaps to Sign in; nothing to show here.
        } else {
            ActivitySkeleton()
                .padding(.top, Spacing.space2)
        }
    }

    private func loaded(_ items: [ActivityItem]) -> some View {
        let banner = refreshFailureMessage
        let updated = freshnessText
        let hasStatusBlock = banner != nil || updated != nil
        return VStack(alignment: .leading, spacing: 0) {
            // Status block (A3.2): banner, 8, freshness line, 24, first content.
            if let banner {
                ErrorBanner(banner) { refresh() }
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space2)
                    .transition(.opacity)
            }
            if let updated {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space2)
                    .transition(.opacity)
            }
            if items.isEmpty {
                // D3: no button (Home's "Add money" is one tab away).
                EmptyState(
                    title: "No activity yet",
                    message: "Money you add, move and pay in shows up here."
                )
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            } else {
                let sections = ActivityDayGrouping.sections(for: items)
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    ActivityDay(section: section) { item in
                        services.navigator.present(.activityReceipt(item))
                    }
                    // The first day 8 below the content top (24 below a status
                    // block); each next day 12 below the previous day's last row.
                    .padding(.top, index == 0 ? (hasStatusBlock ? Spacing.space6 : Spacing.space2) : Spacing.space3)
                }
                if items.count == Self.pageSize {
                    Text("Showing your latest 100 moves.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.top, Spacing.space6)
                        .accessibilityIdentifier("activity.footer")
                }
            }
        }
    }

    /// Shown at the top of the content when a refresh failed but data is still on screen (D5).
    private var refreshFailureMessage: String? {
        guard activity.value != nil, let error = activity.error,
              error != .sessionExpired, error != .cancelled
        else { return nil }
        return error.message(for: .screen)
    }

    /// "Updated …" while the list is the cached snapshot, and while it keeps
    /// rows a refresh failed to replace (D5).
    private var freshnessText: String? {
        if let cached = activity.updatedText() { return cached }
        guard refreshFailureMessage != nil, let updatedAt = activity.updatedAt else { return nil }
        return SnapshotAge.text(savedAt: updatedAt)
    }

    private var statusLines: [Bool] {
        [refreshFailureMessage != nil, freshnessText != nil]
    }

    private func refresh() {
        Task { await activity.refresh() }
    }
}

/// One day: a list header ("Today", "Yesterday", "Monday, Oct 20";
/// `subheadlineEmphasis` `textSecondary`, a header for VoiceOver, its label
/// exactly the visible text) and that day's rows right under it, newest first.
/// No container and no dividers: days are separated by their headers and space.
struct ActivityDay: View {
    let section: ActivityDaySection
    let open: (ActivityItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .textStyle(.subheadlineEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.screenGutter)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("activity.section.\(section.dayKey)")
            ForEach(section.items) { item in
                ActivityRow(item) { open(item) }
                    .accessibilityIdentifier("activity.row.\(item.id)")
            }
        }
    }
}

/// The Activity layout while it loads for the first time (B2.6 D2): two days,
/// each a header bar and three row skeletons at the real row geometry (an
/// 18 pt block in the symbol slot, a title bar, a sub-line bar and a 64 pt
/// amount bar on the trailing gutter), days 12 apart. One VoiceOver element,
/// "Loading activity…".
struct ActivitySkeleton: View {
    var body: some View {
        LoadingPlaceholder(label: "Loading activity\u{2026}") {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                ForEach(0..<2, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonTextLine(.subheadlineEmphasis, leading: 0.3)
                            .padding(.horizontal, Spacing.screenGutter)
                        ForEach(0..<3, id: \.self) { _ in
                            ActivityRowSkeleton(showsSymbol: true)
                        }
                    }
                }
            }
        }
    }
}

#if DEBUG
private enum ActivityPreviewData {
    /// Real-shaped API payload (same fields `GET /activity` returns).
    static func items() -> [ActivityItem] {
        let now = Date()
        func iso(_ offset: TimeInterval) -> String {
            now.addingTimeInterval(offset).formatted(.iso8601)
        }
        let json = """
        [
          {"id":"1","type":"deposit","description":"Test money added","amountCents":50000,"onchainStatus":"none","createdAt":"\(iso(-600))"},
          {"id":"2","type":"goal_allocate","description":"Moved to Emergency fund","amountCents":-20000,"onchainStatus":"pending","createdAt":"\(iso(-3_600))"},
          {"id":"3","type":"contribution","description":"Family susu \\u00b7 round 3","amountCents":-10000,"onchainStatus":"none","createdAt":"\(iso(-90_000))"},
          {"id":"4","type":"goal_allocate","description":"Moved to New laptop","amountCents":-5000,"onchainStatus":"failed","createdAt":"\(iso(-260_000))"}
        ]
        """
        return (try? APICoding.makeDecoder().decode([ActivityItem].self, from: Data(json.utf8))) ?? []
    }
}

#Preview("Activity days") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(ActivityDayGrouping.sections(for: ActivityPreviewData.items())) { section in
                ActivityDay(section: section) { _ in }
            }
        }
    }
    .moolaCanvas()
}

#Preview("Activity skeleton") {
    ScrollView {
        ActivitySkeleton()
    }
    .moolaCanvas()
}
#endif

import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Learn (learn.md L.3, SPEC §3.2), pushed for `AppDestination.learn` from
/// Home and Account: the intro, the progress line and bar, the next lesson on
/// a grey tile, then every visible lesson as a row. Lessons come from `GET
/// /learn/lessons` through `RemoteResource` (`SnapshotKey.lessons`, shared
/// with Home); what is shown and counted is `LearnCatalog`'s visible list
/// (crypto and remittance never show, no emoji). Loading, empty, error and
/// cached-with-a-failed-refresh states; pull to refresh; re-read on every
/// return from a lesson.
public struct LearnListView: View {
    private let services: AppServices

    @State private var lessons: RemoteResource<[LessonSummary]>
    @State private var hasLoaded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(services: AppServices) {
        self.services = services
        let api = services.api
        _lessons = State(initialValue: RemoteResource(cacheKey: .lessons, cache: services.cache) {
            try await api.send(API.Learn.lessons())
        })
    }

    public var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.space8)
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: lessons.error)
        }
        .accessibilityIdentifier("learn.scroll")
        .moolaCanvas()
        .navigationTitle(LearnCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await lessons.refresh() }
        .task {
            // Every appearance: the first loads (snapshot, then network); a
            // return from a lesson re-reads, so a lesson marked done there
            // shows here (L.3).
            if hasLoaded {
                await lessons.refresh()
            } else {
                hasLoaded = true
                await lessons.load()
            }
        }
    }

    private func open(_ lesson: LessonSummary) {
        services.navigator.open(.lesson(slug: lesson.slug))
    }

    // MARK: Content

    /// The status block (ruling 11) 16 pt below the bar, then the intro 24
    /// below it (16 below the bar without one). The intro renders in every
    /// state; what follows it depends on the data.
    @ViewBuilder
    private var content: some View {
        let status = hasStatusBlock
        VStack(alignment: .leading, spacing: 0) {
            if status {
                statusBlock
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space4)
            }
            Text(LearnCopy.intro)
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, status ? Spacing.space6 : Spacing.space4)
                .accessibilityIdentifier("learn.intro")
            if let list = lessons.value {
                loaded(LearnCatalog.visible(list))
            } else if let error = lessons.error {
                // Never loaded: the error in place of everything else, with no
                // count anywhere (never "0 of 3"). It stays while "Try again"
                // retries; the button says "Trying again…" meanwhile.
                ErrorState(title: LearnCopy.listErrorTitle, message: error.message(for: .screen), isRetrying: lessons.isLoading) {
                    Task { await lessons.refresh() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("learn.error")
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            } else {
                loadingSkeleton
            }
        }
    }

    /// Shown only with data: an ErrorBanner when a refresh failed, then 8 pt
    /// below it "Updated {n} min ago" while the list is the snapshot.
    private var hasStatusBlock: Bool {
        lessons.value != nil && (lessons.error != nil || lessons.updatedText() != nil)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let error = lessons.error {
                ErrorBanner(error.message(for: .screen)) {
                    Task { await lessons.refresh() }
                }
                .accessibilityIdentifier("learn.banner")
                .transition(.opacity)
            }
            if let updated = lessons.updatedText() {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("learn.updated")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func loaded(_ visible: [LessonSummary]) -> some View {
        if visible.isEmpty {
            // The server sent no lesson iOS shows: the empty state, never
            // "0 of 0", no tile and no heading.
            EmptyState(title: LearnCopy.emptyTitle, message: LearnCopy.emptyBody)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("learn.empty")
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
        } else {
            let progress = LearnCatalog.progress(of: visible)
            let upNext = LearnCatalog.upNext(in: visible)
            ProgressBlock(done: progress.done, total: progress.total)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            if let upNext {
                FeaturedLessonTile(
                    lesson: upNext,
                    label: progress.done == 0 ? LearnCopy.startHere : LearnCopy.nextLesson
                ) {
                    open(upNext)
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
                .transition(.opacity)
            }
            SectionHeader(LearnCopy.allLessons)
                .accessibilityIdentifier("learn.allHeading")
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.sectionGap)
            // The rows list every visible lesson, the featured one included:
            // they are the record behind the progress line (L.3, Q16). The
            // 68 pt rows' own padding gives `headingToContent`.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { lesson in
                    LessonRow(lesson: lesson) { open(lesson) }
                }
            }
        }
    }

    // MARK: Loading (L.3 "Loading, first load")

    /// The final layout with the values as blocks: the progress line (45 %),
    /// the bar, the tile with its four lines, the real "All lessons" heading
    /// and three rows at the 68 pt pitch. One element "Loading lessons…".
    private var loadingSkeleton: some View {
        LoadingPlaceholder(label: LearnCopy.loadingLessons) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    SkeletonTextLine(.headline, leading: 0.45)
                    // The bar is hidden while the value is unknown (A8.7).
                    SkeletonBlock(height: 6, cornerRadius: 3)
                        .padding(.top, Spacing.space2)
                    FeaturedTileSkeleton()
                        .padding(.top, Spacing.space6)
                    SectionHeader(LearnCopy.allLessons)
                        .padding(.top, Spacing.sectionGap)
                }
                .padding(.horizontal, Spacing.screenGutter)
                ForEach(0..<3, id: \.self) { _ in
                    LessonRowSkeleton()
                }
            }
            .padding(.top, Spacing.space6)
        }
        .accessibilityIdentifier("learn.loading")
    }
}

// MARK: - Pieces

/// "{done} of {total} lessons done" (`headline`, tabular digits), 8 pt, the
/// 6 pt bar: one element whose label is the visible text; the bar is hidden.
/// The bar's width animates only when the count changes on screen.
private struct ProgressBlock: View {
    let done: Int
    let total: Int

    var body: some View {
        let text = LearnCatalog.progressText(done: done, total: total)
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(text)
                .textStyle(.headline)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressBar(
                fraction: total > 0 ? Double(done) / Double(total) : 0,
                height: 6,
                hasProgress: done > 0
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("learn.progress")
    }
}

/// The next lesson not yet done, on a grey tile (A8.5, ruling 31): the
/// label, the title (`bodyEmphasis`, D-15), the summary and the meta line;
/// every line wraps and none truncates. One button.
private struct FeaturedLessonTile: View {
    let lesson: LessonSummary
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: lesson.title)
                    .textStyle(.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space1)
                if !lesson.summary.isEmpty {
                    Text(verbatim: lesson.summary)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.space2)
                }
                if let meta = LearnCatalog.meta(minutes: lesson.minutes, level: lesson.level) {
                    Text(meta.keepingMiddleDotsAtLineEnds)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.space3)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tileStyle(fill: false)
        }
        .buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
        .accessibilityLabel(Text(verbatim: lesson.title))
        .accessibilityValue(Text(verbatim: LearnCopy.featuredValue(label: label, lesson: lesson)))
        .accessibilityHint(LearnCopy.opensLesson)
        .accessibilityIdentifier("learn.featured")
    }
}

/// One visible lesson (A8.21): no symbol, the title on one line (D-40), the
/// category and minutes, "Done" when it is, the chevron. One button: label
/// the title, value "{Category}, {n} minutes" (", done").
private struct LessonRow: View {
    let lesson: LessonSummary
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let subtitle = LearnCatalog.rowSubtitle(lesson)
        SettingsRow(
            symbol: nil,
            title: lesson.title,
            subtitle: subtitle.isEmpty ? nil : subtitle.keepingMiddleDotsAtLineEnds,
            value: lesson.completed ? LearnCopy.done : nil,
            titleLineLimit: 1,
            action: action
        )
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: lesson.completed)
        .accessibilityLabel(Text(verbatim: lesson.title))
        .accessibilityValue(Text(verbatim: LearnCopy.rowValue(lesson)))
        .accessibilityHint(LearnCopy.opensLesson)
        .accessibilityIdentifier("learn.lesson.\(lesson.slug)")
    }
}

/// The featured tile while the list loads: the real `surface` tile with
/// `fillPressed` bars on its lines (label 25 %, title 60 %, two summary lines
/// 90 % and 70 %, meta 30 %), each line at its loaded height.
private struct FeaturedTileSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonTextLine(.subheadline, leading: 0.25, color: Palette.fillPressed)
            SkeletonTextLine(.bodyEmphasis, leading: 0.6, color: Palette.fillPressed)
                .padding(.top, Spacing.space1)
            VStack(alignment: .leading, spacing: TypeToken.subheadline.lineSpacing) {
                SkeletonTextLine(.subheadline, leading: 0.9, color: Palette.fillPressed)
                SkeletonTextLine(.subheadline, leading: 0.7, color: Palette.fillPressed)
            }
            .padding(.top, Spacing.space2)
            SkeletonTextLine(.footnote, leading: 0.3, color: Palette.fillPressed)
                .padding(.top, Spacing.space3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tileStyle()
    }
}

/// A lesson row's skeleton: 68 pt, the title bar (60 %) and the sub-line bar
/// (35 %) at the row's text column.
private struct LessonRowSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SkeletonTextLine(.body, leading: 0.6)
            SkeletonTextLine(.subheadline, leading: 0.35)
        }
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    }
}

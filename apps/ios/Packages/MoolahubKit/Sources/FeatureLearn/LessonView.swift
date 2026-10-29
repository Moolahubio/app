import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// One lesson (learn.md L.4, SPEC §3.3), pushed for
/// `AppDestination.lesson(slug:)`: the title in the content (`titleLarge`),
/// minutes and level, the summary, the sections in a reading rhythm (D-12),
/// key takeaways, then Mark as done (L.6: not optimistic, stays on the
/// lesson) or Done, then the next visible lesson (L.7, no wrap-around). The
/// bar has no title until the content title has scrolled fully under it.
///
/// The lesson comes from `GET /learn/lessons/{slug}` through `RemoteResource`
/// (`SnapshotKey.lesson(_:)`, so a lesson read once opens offline); the list
/// (`SnapshotKey.lessons`) only prefills the header and finds the next
/// lesson. Lesson text is plain text, drawn verbatim. A lesson outside the
/// shown categories, a 404 and a 400 show "We couldn't find that lesson."
public struct LessonView: View {
    private let services: AppServices
    private let slug: String

    @State private var lesson: RemoteResource<LessonDetail>
    @State private var lessons: RemoteResource<[LessonSummary]>
    @State private var hasLoaded = false
    @State private var isSaving = false
    /// Set once the server answered 200 to Mark as done: "Mark as done" never
    /// shows again on this screen, even if a later read lags (L.4).
    @State private var markedDone = false
    @State private var markDoneError: String?
    @State private var failureTick = 0
    @State private var titleIsUnderBar = false
    /// VoiceOver focus goes to the title on the first arrival only: Back
    /// from the next lesson shows the title again, and focus then stays
    /// where iOS restores it (the next row).
    @State private var didFocusTitle = false
    @AccessibilityFocusState private var titleFocused: Bool
    /// After this screen's Mark as done, focus moves from the button that
    /// had it to the Done line that replaces it.
    @AccessibilityFocusState private var doneFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Mark as done or Done: scrolled back into view when a failure banner
    /// goes in above the button.
    private static let actionID = "lesson.action"

    public init(services: AppServices, slug: String) {
        self.services = services
        self.slug = slug
        let api = services.api
        _lesson = State(initialValue: RemoteResource(cacheKey: .lesson(slug), cache: services.cache) {
            try await api.send(API.Learn.lesson(slug))
        })
        _lessons = State(initialValue: RemoteResource(cacheKey: .lessons, cache: services.cache) {
            try await api.send(API.Learn.lessons())
        })
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Spacing.space8)
                    .animation(standardAnimation, value: lesson.error)
            }
            .coordinateSpace(.named(LessonScrollSpace.name))
            .accessibilityIdentifier("lesson.scroll")
            .moolaCanvas()
            .navigationTitle(barTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onPreferenceChange(LessonTitleMaxYKey.self) { maxY in
                let isUnder = maxY <= 0
                if isUnder != titleIsUnderBar { titleIsUnderBar = isUnder }
            }
            .task { await loadOnAppear() }
            .sensoryFeedback(.error, trigger: failureTick)
            .onChange(of: markDoneError) { _, error in
                // The banner pushes the button, the only retry, down, maybe
                // under the tab bar: scroll the least that shows it whole.
                guard error != nil else { return }
                withAnimation(standardAnimation) { proxy.scrollTo(Self.actionID) }
            }
        }
    }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    /// Empty at rest; the lesson title once the content title has scrolled
    /// fully under the bar (SPEC §3.3). The system fades the swap.
    private var barTitle: String {
        guard titleIsUnderBar, case .ready(let header?, _) = state else { return "" }
        return header.title
    }

    /// The first appearance reads the lesson and the list together (each
    /// from its snapshot first). A later one (back from the next lesson)
    /// starts again only a read that never finished, because its screen was
    /// covered while it ran.
    private func loadOnAppear() async {
        if hasLoaded {
            async let detail: Void = loadIfMissing(lesson)
            async let list: Void = loadIfMissing(lessons)
            _ = await (detail, list)
        } else {
            hasLoaded = true
            async let detail: Void = lesson.load()
            async let list: Void = lessons.load()
            _ = await (detail, list)
        }
    }

    private func loadIfMissing<Value: Codable & Sendable>(_ resource: RemoteResource<Value>) async {
        guard resource.value == nil, resource.error == nil, !resource.isLoading else { return }
        await resource.load()
    }

    /// "Try again" on the error state or the banner: the lesson, and the list
    /// too when it never loaded (the next row needs it).
    private func retry() async {
        async let detail: Void = lesson.refresh()
        async let list: Void = lessons.value == nil ? lessons.refresh() : ()
        _ = await (detail, list)
    }

    // MARK: State

    private enum ReaderState {
        /// 404, 400, or a lesson in a category iOS never shows.
        case notFound
        /// Never loaded.
        case failed(APIError)
        /// The header (from the lesson, else prefilled from the list) and the
        /// lesson once it has landed.
        case ready(header: LessonHeader?, detail: LessonDetail?)
    }

    private var state: ReaderState {
        if LessonErrors.isNotFound(lesson.error) { return .notFound }
        if let detail = lesson.value {
            // The server serves every lesson; the visibility guard is iOS's.
            guard LearnCatalog.isShown(category: detail.category) else { return .notFound }
            return .ready(header: LessonHeader(detail), detail: detail)
        }
        if let error = lesson.error { return .failed(error) }
        let prefill = LearnCatalog.visible(lessons.value ?? []).first { $0.slug == slug }
        return .ready(header: prefill.map(LessonHeader.init), detail: nil)
    }

    /// Done from the server, or after this screen's Mark as done.
    private func isDone(_ detail: LessonDetail) -> Bool {
        markedDone || detail.completed
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .notFound:
            // The 404 variant, title only, no button: the system Back is the
            // way out (the reader opens from Home and from the list, Q18).
            Text(LearnCopy.notFound)
                .textStyle(.title2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("lesson.notFound")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space4)
        case .failed(let error):
            ErrorState(title: LearnCopy.lessonErrorTitle, message: error.message(for: .screen), isRetrying: lesson.isLoading) {
                Task { await retry() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lesson.error")
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space4)
        case .ready(let header, let detail):
            if let header {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerBlock(header)
                        if let detail {
                            article(detail)
                            actions(detail)
                        } else {
                            LoadingPlaceholder(label: LearnCopy.loadingLesson) {
                                ArticleSkeleton()
                            }
                            .accessibilityIdentifier("lesson.loading")
                        }
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    if detail != nil, let next = nextLesson {
                        nextRow(next)
                            .padding(.top, Spacing.space6)
                            .transition(.opacity)
                    }
                }
                .animation(standardAnimation, value: nextLesson?.slug)
            } else {
                LoadingPlaceholder(label: LearnCopy.loadingLesson) {
                    VStack(alignment: .leading, spacing: 0) {
                        HeaderSkeleton()
                        ArticleSkeleton()
                    }
                }
                .accessibilityIdentifier("lesson.loading")
                .padding(.horizontal, Spacing.screenGutter)
            }
        }
    }

    /// The status block 12 pt below the bar, then the title 24 below it (12
    /// below the bar without one), the meta 8 below, the summary 24 below.
    @ViewBuilder
    private func headerBlock(_ header: LessonHeader) -> some View {
        let status = hasStatusBlock
        if status {
            statusBlock
                .padding(.top, Spacing.space3)
        }
        Text(verbatim: header.title)
            .textStyle(.titleLarge)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("lesson.title")
            .accessibilityFocused($titleFocused)
            .reportsLessonTitleMaxY()
            .onAppear {
                guard !didFocusTitle else { return }
                didFocusTitle = true
                titleFocused = true
            }
            .padding(.top, status ? Spacing.space6 : Spacing.space3)
        if let meta = LearnCatalog.meta(minutes: header.minutes, level: header.level) {
            Text(meta.keepingMiddleDotsAtLineEnds)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(LearnCatalog.metaSpoken(minutes: header.minutes, level: header.level) ?? meta)
                .accessibilityIdentifier("lesson.meta")
                .padding(.top, Spacing.space2)
        }
        if !header.summary.isEmpty {
            Text(verbatim: header.summary)
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lesson.summary")
                .padding(.top, Spacing.space6)
        }
    }

    /// Only with a lesson on screen: an ErrorBanner when a refresh failed,
    /// then 8 pt below it "Updated {n} min ago" while it is the snapshot.
    private var hasStatusBlock: Bool {
        lesson.value != nil && (lesson.error != nil || lesson.updatedText() != nil)
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let error = lesson.error {
                ErrorBanner(error.message(for: .screen)) {
                    Task { await retry() }
                }
                .accessibilityIdentifier("lesson.banner")
                .transition(.opacity)
            }
            if let updated = lesson.updatedText() {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("lesson.updated")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The article is one reading flow (D-12): each sub-heading 24 below the
    /// summary or the previous paragraph, its paragraph 8 below it. "Key
    /// takeaways" is a screen section: 52 above, 16 to the first item, 12
    /// between items. A block whose text is empty is left out.
    @ViewBuilder
    private func article(_ detail: LessonDetail) -> some View {
        ForEach(Array(detail.body.enumerated()), id: \.offset) { index, section in
            if !section.heading.isEmpty {
                Text(verbatim: section.heading)
                    .textStyle(.title3)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("lesson.section.\(index).heading")
                    .padding(.top, Spacing.space6)
            }
            if !section.text.isEmpty {
                Text(verbatim: section.text)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lesson.section.\(index).text")
                    .padding(.top, section.heading.isEmpty ? Spacing.space6 : Spacing.space2)
            }
        }
        let takeaways = detail.takeaways.filter { !$0.isEmpty }
        if !takeaways.isEmpty {
            SectionHeader(LearnCopy.keyTakeaways)
                .accessibilityIdentifier("lesson.takeaways")
                .padding(.top, Spacing.sectionGap)
            VStack(alignment: .leading, spacing: Spacing.space3) {
                ForEach(Array(takeaways.enumerated()), id: \.offset) { index, takeaway in
                    TakeawayItem(text: takeaway, index: index)
                }
            }
            .padding(.top, Spacing.headingToContent)
        }
    }

    /// 24 pt below the last takeaway (or paragraph): after a failed save the
    /// banner, then 12 pt to the button; "Mark as done" and "Done" share one
    /// 50 pt frame, so nothing below moves when they swap.
    private func actions(_ detail: LessonDetail) -> some View {
        let done = isDone(detail)
        return VStack(alignment: .leading, spacing: 0) {
            if let markDoneError, !done {
                ErrorBanner(markDoneError)
                    .accessibilityIdentifier("lesson.markDone.error")
                    .padding(.bottom, Spacing.space3)
                    .transition(.opacity)
            }
            ZStack(alignment: .leading) {
                if done {
                    DoneStatus(focus: $doneFocused)
                        .transition(.opacity)
                } else {
                    MoolaButton(LearnCopy.markAsDone, loadingTitle: LearnCopy.saving, isLoading: isSaving) {
                        markDone()
                    }
                    .accessibilityIdentifier("lesson.markDone")
                    .transition(.opacity)
                }
            }
            .id(Self.actionID)
        }
        .padding(.top, Spacing.space6)
        .animation(standardAnimation, value: done)
        .animation(standardAnimation, value: markDoneError)
    }

    // MARK: Next lesson (L.7)

    /// The visible lesson right after this one in server order, whatever its
    /// done state; none after the last (no wrap-around), and none while the
    /// list is loading or has failed.
    private var nextLesson: LessonSummary? {
        guard let list = lessons.value else { return nil }
        return LearnCatalog.next(after: slug, in: LearnCatalog.visible(list))
    }

    private func nextRow(_ next: LessonSummary) -> some View {
        SettingsRow(
            symbol: nil,
            title: next.title,
            subtitle: LearnCopy.nextLessonSubtitle(minutes: next.minutes).keepingMiddleDotsAtLineEnds,
            titleLineLimit: 1
        ) {
            // A push on the same stack; Back returns to this lesson.
            services.navigator.open(.lesson(slug: next.slug))
        }
        .accessibilityLabel(Text(verbatim: LearnCopy.nextLessonLabel(next.title)))
        .accessibilityValue(Text(verbatim: LearnCatalog.minutesSpoken(next.minutes) ?? ""))
        .accessibilityHint(LearnCopy.opensLesson)
        .accessibilityIdentifier("lesson.next")
    }

    // MARK: Mark as done (L.6)

    /// Not optimistic: "Done" appears only after the server's 200, and the
    /// person stays on the lesson. While saving the button ignores taps, so
    /// the request is never sent twice; it completes even if the screen
    /// goes away. A failure keeps "Mark as done" with a banner above it and
    /// plays `.error` once.
    private func markDone() {
        guard !isSaving else { return }
        markDoneError = nil
        isSaving = true
        let api = services.api
        let cache = services.cache
        let slug = slug
        // The resources are taken now, while the screen is on screen: the
        // request outlives a screen that goes away meanwhile.
        let detail = lesson
        let list = lessons
        Task {
            do throws(APIError) {
                _ = try await api.send(API.Learn.complete(slug))
                isSaving = false
                markedDone = true
                doneFocused = true
                // High priority: the focus move to Done must not cut it off.
                var announcement = AttributedString(LearnCopy.markedAsDone)
                announcement.accessibilitySpeechAnnouncementPriority = .high
                AccessibilityNotification.Announcement(announcement).post()
                await Self.refreshSnapshotsAfterDone(slug: slug, api: api, cache: cache, detail: detail, list: list)
            } catch {
                isSaving = false
                guard let message = LessonErrors.markDoneMessage(error) else { return }
                markDoneError = message
                failureTick += 1
            }
        }
    }

    /// Re-reads the lesson and the list to update both snapshots (Home and
    /// the list pick them up). A failure here shows nothing: the local Done
    /// stands.
    private static func refreshSnapshotsAfterDone(
        slug: String,
        api: APIClient,
        cache: SnapshotCache,
        detail: RemoteResource<LessonDetail>,
        list: RemoteResource<[LessonSummary]>
    ) async {
        if let fresh = try? await api.send(API.Learn.lesson(slug)) {
            detail.replace(with: fresh)
            await cache.save(fresh, for: .lesson(slug))
        }
        if let lessons = try? await api.send(API.Learn.lessons()) {
            list.replace(with: lessons)
            await cache.save(lessons, for: .lessons)
        }
    }
}

// MARK: - Pieces

/// What the header draws, from the lesson or prefilled from the list.
private struct LessonHeader: Equatable {
    let title: String
    let summary: String
    let minutes: Int
    let level: String

    init(_ detail: LessonDetail) {
        title = detail.title
        summary = detail.summary
        minutes = detail.minutes
        level = detail.level
    }

    init(_ summary: LessonSummary) {
        title = summary.title
        self.summary = summary.summary
        minutes = summary.minutes
        level = summary.level
    }
}

/// One takeaway: a bullet centred in the 24 pt symbol slot at x 16 to 40
/// (hidden from VoiceOver), the text at x 52. At accessibility sizes the
/// bullet is dropped and the text starts at the gutter (L.4).
private struct TakeawayItem: View {
    let text: String
    let index: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: "\u{2022}")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("lesson.takeaway.\(index)")
        }
    }
}

/// The done line in Mark as done's place: `checkmark.circle.fill` (`jadeFill`)
/// centred in the 24 pt slot, then "Done" (`headline` `jadeText`) at x 52, in
/// the button's 50 pt frame; the symbol goes above the word when they do not
/// fit. One static text, "Done", that takes VoiceOver focus through `focus`.
private struct DoneStatus: View {
    let focus: AccessibilityFocusState<Bool>.Binding

    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.space3) {
                symbol.frame(width: max(24, symbolSize))
                word
            }
            VStack(alignment: .leading, spacing: Spacing.space1) {
                symbol
                word
            }
        }
        .frame(maxWidth: .infinity, minHeight: Size.buttonHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LearnCopy.done)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("lesson.done")
        .accessibilityFocused(focus)
    }

    private var symbol: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(Palette.jadeFill)
    }

    private var word: some View {
        Text(LearnCopy.done)
            .textStyle(.headline)
            .foregroundStyle(Palette.jadeText)
            .fixedSize()
    }
}

/// The title (70 %), meta (30 %) and summary (100, 100, 60 %) bars, each at
/// its loaded line height, at the header's spacing.
private struct HeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonTextLine(.titleLarge, leading: 0.7)
                .padding(.top, Spacing.space3)
            SkeletonTextLine(.subheadline, leading: 0.3)
                .padding(.top, Spacing.space2)
            ParagraphSkeleton(lastLine: 0.6, lines: 3)
                .padding(.top, Spacing.space6)
        }
    }
}

/// Two sections in the reading rhythm: a heading bar (50 %) 24 below, its
/// paragraph 8 below (four lines, then three; the last line 60 %).
private struct ArticleSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkeletonTextLine(.title3, leading: 0.5)
                .padding(.top, Spacing.space6)
            ParagraphSkeleton(lastLine: 0.6, lines: 4)
                .padding(.top, Spacing.space2)
            SkeletonTextLine(.title3, leading: 0.5)
                .padding(.top, Spacing.space6)
            ParagraphSkeleton(lastLine: 0.6, lines: 3)
                .padding(.top, Spacing.space2)
        }
    }
}

/// `lines` full-width `body` bars at the 21 pt pitch, the last `lastLine` wide.
private struct ParagraphSkeleton: View {
    let lastLine: CGFloat
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: TypeToken.body.lineSpacing) {
            ForEach(0..<lines, id: \.self) { line in
                SkeletonTextLine(.body, leading: line == lines - 1 ? lastLine : 1)
            }
        }
    }
}

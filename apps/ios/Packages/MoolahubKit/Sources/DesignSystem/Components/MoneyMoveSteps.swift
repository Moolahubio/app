import Domain
import SwiftUI

// MARK: - DetailRow (DESIGN.md v2 A8.17)

/// One label/value fact in a review, a receipt or a detail screen.
public struct DetailRow: Identifiable {
    public enum Value {
        /// Words: `headline` (16 Medium) `textPrimary`.
        case text(String)
        /// Money: `amountRow`.
        case money(Money)
        /// "No fee" when zero, otherwise the amount.
        case fee(Money)
        /// A StatusPill (receipts only).
        case status(MoveStatus)
        /// A goal: its 32 pt EmojiTile 8 pt before the goal name ("To" / "From").
        case goal(name: String, emoji: String?, colorKey: String?)
    }

    public let label: String
    public let value: Value
    /// Optional leading symbol (A7.3), 18 pt Regular `textSecondary` in a 24 pt slot.
    public let symbol: String?

    public var id: String { label }

    public init(_ label: String, _ value: Value, symbol: String? = nil) {
        self.label = label
        self.value = value
        self.symbol = symbol
    }
}

/// A `DetailRow` on the page (A8.17): 48 pt min; label (`body` `textSecondary`)
/// leading, value trailing, centred on each other; no dividers, no container.
/// At accessibility sizes the label sits above the value, both leading. One
/// accessibility element whose label begins with the row's label (tests:
/// BEGINSWITH "Status" CONTAINS "Done").
public struct DetailRowView: View {
    let row: DetailRow

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 24

    public init(_ row: DetailRow) {
        self.row = row
    }

    public var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = accessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space1))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.space3))
        layout {
            HStack(spacing: Spacing.space3) {
                if let symbol = row.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize, weight: .regular))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: symbolSlot, height: symbolSlot)
                        .accessibilityHidden(true)
                }
                Text(row.label)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !accessibilitySize {
                Spacer(minLength: Spacing.space3)
            }
            value
        }
        .padding(.vertical, Spacing.space2)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var value: some View {
        switch row.value {
        case .text(let text):
            Text(text)
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        case .money(let money):
            MoneyText(money, style: .amountRow)
        case .fee(let money):
            if money.isZero {
                Text("No fee")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
            } else {
                MoneyText(money, style: .amountRow)
            }
        case .status(let status):
            StatusPill(status: status)
        case .goal(let name, let emoji, let colorKey):
            HStack(spacing: Spacing.space2) {
                EmojiTile(emoji: emoji, colorKey: colorKey, fallbackName: name, size: .s32)
                Text(name)
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The receipt symbol (A5.6)

/// The receipt's status (J0.5): Domain's `MoveStatus`.
public typealias ReceiptStatus = MoveStatus

/// The receipt symbol (A5.6), 56 pt fixed and hidden (decorative). Processing:
/// `clock` in `textSecondary` (a normal state, no status colour). Done:
/// `checkmark.circle.fill`, palette (check `canvas`, circle `jadeFill`), one
/// bounce. Didn't go through: `xmark.circle.fill`, palette (cross `canvas`,
/// circle `redText`), no bounce. Changes swap with `.symbolEffect(.replace)`;
/// Reduce Motion removes the effects.
public struct ReceiptSymbol: View {
    let status: MoveStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(status: MoveStatus) {
        self.status = status
    }

    public var body: some View {
        Image(systemName: name)
            .font(.system(size: 56, weight: .regular))
            .symbolRenderingMode(status == .processing ? .monochrome : .palette)
            .foregroundStyle(primary, secondary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, options: .nonRepeating, value: status == .done)
            .symbolEffectsRemoved(reduceMotion)
            .accessibilityHidden(true)
    }

    private var name: String {
        switch status {
        case .processing: "clock"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var primary: Color {
        switch status {
        case .processing: Palette.textSecondary
        case .done, .failed: Palette.canvas
        }
    }

    private var secondary: Color {
        switch status {
        case .processing: Palette.textSecondary
        case .done: Palette.jadeFill
        case .failed: Palette.redText
        }
    }
}

// MARK: - ReviewStep (A8.15, J0.3)

/// The last step before a money move (A8.15). Presentational: the feature
/// runs `DeviceAuthenticator` and the request and passes the state in.
///
/// Content at the 20 pt sheet inset: title (`title1`, "Review" or "Pay in"),
/// optional subtitle (`body` `textSecondary`), 32 pt, the amount
/// (`displayAmount`, centred), 32 pt, the `DetailRow`s with no container, an
/// optional standing note (`footnote`, no identifier) 12 pt below.
///
/// Pinned bar, top to bottom: the ErrorBanner (`<prefix>.error`; refusal title
/// "Didn't go through. Nothing was taken.", or "View activity" after an
/// uncertain move), the confirm button (`<prefix>.confirm`), the reserved reason
/// slot (the Face ID cancel line "Cancelled. Nothing was taken." as
/// `<prefix>.note`, or the flow's `reason`), the optional secondary
/// (`belowConfirm`), and "Edit amount". At accessibility sizes the bar holds
/// only the confirm button; the rest moves into the content under the rows.
///
/// Identifiers: `<prefix>.amount`, `.confirm`, `.note`, `.error`.
public struct ReviewStep<AboveConfirm: View, BelowConfirm: View>: View {
    let title: String
    let subtitle: String?
    let amount: Money
    let rows: [DetailRow]
    let footnote: String?
    let confirmTitle: String
    let confirmSystemImage: String?
    let isConfirming: Bool
    let note: String?
    let reason: String?
    let reasonIsRefusal: Bool
    let reasonIdentifier: String?
    let errorTitle: String?
    let errorMessage: String?
    let errorActionTitle: String?
    let onErrorAction: (() -> Void)?
    let isConfirmDisabled: Bool
    let blocksGoingBack: Bool
    let identifierPrefix: String
    let onConfirm: () -> Void
    let onEditAmount: (() -> Void)?
    let aboveConfirm: AboveConfirm
    let belowConfirm: BelowConfirm

    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - title: "Review"; "Pay in" for a group pay-in (J5).
    ///   - subtitle: the group or goal name under the title.
    ///   - footnote: the standing note under the rows ("Pay-ins can't be undone.").
    ///   - confirmTitle: "Confirm with Face ID" etc. (`BiometryKind.confirmTitle`).
    ///   - note: "Cancelled. Nothing was taken." after a cancelled Face ID (reason slot, `<prefix>.note`).
    ///   - reason: why the confirm is disabled ("Loading your balance…"); `reasonIsRefusal` draws it in `redText`.
    ///   - errorTitle: "Didn't go through. Nothing was taken." for refusals (J0.7).
    ///   - errorActionTitle: the banner's action ("View activity" after an uncertain move).
    ///   - blocksGoingBack: hides Back (also while confirming), for example after an uncertain move.
    ///   - onEditAmount: nil hides "Edit amount" (no keypad step).
    ///   - aboveConfirm: v1 slot; drawn in the reason area under the confirm button (prefer `reason`).
    ///   - belowConfirm: the optional secondary ("Add test money").
    public init(
        title: String = "Review",
        subtitle: String? = nil,
        amount: Money,
        rows: [DetailRow],
        footnote: String? = nil,
        confirmTitle: String,
        confirmSystemImage: String?,
        isConfirming: Bool,
        note: String? = nil,
        reason: String? = nil,
        reasonIsRefusal: Bool = false,
        reasonIdentifier: String? = nil,
        errorTitle: String? = nil,
        errorMessage: String? = nil,
        errorActionTitle: String? = nil,
        onErrorAction: (() -> Void)? = nil,
        isConfirmDisabled: Bool = false,
        blocksGoingBack: Bool = false,
        identifierPrefix: String = "review",
        onConfirm: @escaping () -> Void,
        onEditAmount: (() -> Void)? = nil,
        @ViewBuilder aboveConfirm: () -> AboveConfirm,
        @ViewBuilder belowConfirm: () -> BelowConfirm
    ) {
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.rows = rows
        self.footnote = footnote
        self.confirmTitle = confirmTitle
        self.confirmSystemImage = confirmSystemImage
        self.isConfirming = isConfirming
        self.note = note
        self.reason = reason
        self.reasonIsRefusal = reasonIsRefusal
        self.reasonIdentifier = reasonIdentifier
        self.errorTitle = errorTitle
        self.errorMessage = errorMessage
        self.errorActionTitle = errorActionTitle
        self.onErrorAction = onErrorAction
        self.isConfirmDisabled = isConfirmDisabled
        self.blocksGoingBack = blocksGoingBack
        self.identifierPrefix = identifierPrefix
        self.onConfirm = onConfirm
        self.onEditAmount = onEditAmount
        self.aboveConfirm = aboveConfirm()
        self.belowConfirm = belowConfirm()
    }

    private var showsEditAmount: Bool { onEditAmount != nil && !isConfirming && !blocksGoingBack }

    /// A9.9: reserved when the confirm uses Face ID or can be disabled.
    private var reservesReasonSlot: Bool {
        confirmSystemImage != nil || isConfirmDisabled || note != nil || reason != nil
    }

    private var bannerID: String { "\(identifierPrefix).error" }

    public var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text(title)
                            .textStyle(.title1)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($titleFocused)
                        if let subtitle {
                            Text(subtitle)
                                .textStyle(.body)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, Spacing.space2)
                    MoneyText(amount, style: .displayAmount)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("\(identifierPrefix).amount")
                        .padding(.top, Spacing.space8)
                    VStack(spacing: 0) {
                        ForEach(rows) { DetailRowView($0) }
                    }
                    .padding(.top, Spacing.space8)
                    if let footnote {
                        Text(footnote)
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Spacing.space3)
                    }
                    if accessibilitySize {
                        VStack(alignment: .leading, spacing: Spacing.space3) {
                            banner
                            reasonSlot
                            aboveConfirm
                            belowConfirm
                            editAmount
                        }
                        .padding(.top, Spacing.space6)
                    }
                }
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.bottom, Spacing.space6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: errorMessage) { _, newValue in
                guard accessibilitySize, newValue != nil else { return }
                withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) { proxy.scrollTo(bannerID, anchor: .center) }
            }
        }
        .modifier(PinnedActionBar(
            inset: Spacing.sheetPadding,
            ground: .sheet,
            hardEdge: !accessibilitySize && (reservesReasonSlot || showsEditAmount)
        ) {
            VStack(spacing: 0) {
                if !accessibilitySize {
                    banner.padding(.bottom, errorMessage == nil ? 0 : Spacing.space3)
                }
                MoolaButton(
                    confirmTitle,
                    systemImage: confirmSystemImage,
                    loadingTitle: "Confirming\u{2026}",
                    isLoading: isConfirming,
                    action: onConfirm
                )
                .disabled(isConfirmDisabled)
                .accessibilityHint(isConfirmDisabled ? (reason ?? "") : "")
                .accessibilityIdentifier("\(identifierPrefix).confirm")
                if !accessibilitySize {
                    if reservesReasonSlot {
                        reasonSlot.padding(.top, Spacing.space2)
                    }
                    aboveConfirm
                    VStack(spacing: Spacing.space1) {
                        belowConfirm
                        editAmount
                    }
                    .padding(.top, Spacing.space3)
                }
            }
        })
        .interactiveDismissDisabled(isConfirming)
        .navigationBarBackButtonHidden(isConfirming || blocksGoingBack)
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var banner: some View {
        if let errorMessage {
            Group {
                if let errorActionTitle, let onErrorAction {
                    ErrorBanner(errorMessage, title: errorTitle, retryTitle: errorActionTitle, retry: onErrorAction)
                } else {
                    ErrorBanner(errorMessage, title: errorTitle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .accessibilityIdentifier(bannerID)
            .id(bannerID)
        }
    }

    @ViewBuilder
    private var reasonSlot: some View {
        if let note {
            DisabledReasonLine(text: note)
                .accessibilityIdentifier("\(identifierPrefix).note")
        } else if let reason {
            DisabledReasonLine(text: reason, color: reasonIsRefusal ? Palette.redText : Palette.textSecondary)
                .modifier(OptionalIdentifier(identifier: reasonIdentifier))
        } else {
            // Reserved: one footnote line kept while nothing needs saying.
            DisabledReasonLine(text: " ", isShown: false)
        }
    }

    @ViewBuilder
    private var editAmount: some View {
        if showsEditAmount, let onEditAmount {
            TextLinkButton("Edit amount", action: onEditAmount)
        }
    }
}

extension ReviewStep where AboveConfirm == EmptyView, BelowConfirm == EmptyView {
    /// A review with nothing beside the confirm button but its reason slot.
    public init(
        title: String = "Review",
        subtitle: String? = nil,
        amount: Money,
        rows: [DetailRow],
        footnote: String? = nil,
        confirmTitle: String,
        confirmSystemImage: String?,
        isConfirming: Bool,
        note: String? = nil,
        reason: String? = nil,
        reasonIsRefusal: Bool = false,
        reasonIdentifier: String? = nil,
        errorTitle: String? = nil,
        errorMessage: String? = nil,
        errorActionTitle: String? = nil,
        onErrorAction: (() -> Void)? = nil,
        isConfirmDisabled: Bool = false,
        blocksGoingBack: Bool = false,
        identifierPrefix: String = "review",
        onConfirm: @escaping () -> Void,
        onEditAmount: (() -> Void)? = nil
    ) {
        self.init(
            title: title, subtitle: subtitle, amount: amount, rows: rows, footnote: footnote,
            confirmTitle: confirmTitle, confirmSystemImage: confirmSystemImage, isConfirming: isConfirming,
            note: note, reason: reason, reasonIsRefusal: reasonIsRefusal, reasonIdentifier: reasonIdentifier,
            errorTitle: errorTitle, errorMessage: errorMessage,
            errorActionTitle: errorActionTitle, onErrorAction: onErrorAction,
            isConfirmDisabled: isConfirmDisabled, blocksGoingBack: blocksGoingBack,
            identifierPrefix: identifierPrefix, onConfirm: onConfirm, onEditAmount: onEditAmount,
            aboveConfirm: { EmptyView() }, belowConfirm: { EmptyView() }
        )
    }
}

// MARK: - ReceiptStep (A8.16, J0.6)

/// The receipt after a money move (A8.16). The feature decides the status by
/// matching `GET /activity` (J0.6, never a guess) and passes it in.
///
/// 24 pt below the sheet toolbar, centred: `ReceiptSymbol` (56); 16 pt; the
/// title (`title1`, wraps, announced); 8 pt; the amount (`displayAmount`;
/// unsigned on flow receipts, signed on the Activity receipt); 32 pt; the
/// rows (the caller's rows, which include "Date", plus "Status"); 12 pt; the
/// note (`footnote` `textSecondary`, leading). When the move did not go
/// through, flow receipts change their title to "Didn't go through" and the
/// note to "Nothing was taken."; the Activity receipt passes
/// `failedTitle: nil` to keep the move's description. Pinned: primary "Done"
/// and an optional secondary 12 pt above it ("View goal"). `.success` fires
/// when the status becomes Done, `.error` when it becomes Didn't go through.
///
/// An optional `footnote` (ST.3.4, the streak note) sits 12 pt under the
/// note, or under the rows when no note shows: `footnote` `textSecondary`,
/// leading, wraps; hidden while the move did not go through; fades in with
/// `Motion.standard` when it arrives after the receipt is up; not announced;
/// its own static text with the caller's `footnoteIdentifier`.
public struct ReceiptStep: View {
    let status: MoveStatus
    let title: String
    let amount: Money?
    let amountDirection: MoneyDirection
    let amountIdentifier: String?
    let rows: [DetailRow]
    let processingNote: String
    let failedTitle: String?
    let secondaryTitle: String?
    let footnote: String?
    let footnoteIdentifier: String?
    let onDone: () -> Void
    let onSecondary: (() -> Void)?

    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - amount: nil hides the amount line (an Activity item without one).
    ///   - amountDirection: `.none` on flow receipts; the Activity receipt passes the sign.
    ///   - processingNote: the Activity receipt passes "This can take a few minutes.".
    ///   - failedTitle: the title when the move did not go through (nil keeps `title`).
    ///   - footnote: the streak note (ST-70, ST-71), nil for none.
    ///   - footnoteIdentifier: `savings.receipt.streakNote`, `groups.payIn.streakNote`.
    public init(
        status: MoveStatus,
        title: String,
        amount: Money?,
        amountDirection: MoneyDirection = .none,
        amountIdentifier: String? = nil,
        rows: [DetailRow],
        processingNote: String = "This can take a few minutes. We'll show it in Activity when it's done.",
        failedTitle: String? = "Didn't go through",
        secondaryTitle: String? = nil,
        footnote: String? = nil,
        footnoteIdentifier: String? = nil,
        onDone: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil
    ) {
        self.status = status
        self.title = title
        self.amount = amount
        self.amountDirection = amountDirection
        self.amountIdentifier = amountIdentifier
        self.rows = rows
        self.processingNote = processingNote
        self.failedTitle = failedTitle
        self.secondaryTitle = secondaryTitle
        self.footnote = footnote
        self.footnoteIdentifier = footnoteIdentifier
        self.onDone = onDone
        self.onSecondary = onSecondary
    }

    private var shownTitle: String {
        status == .failed ? (failedTitle ?? title) : title
    }

    private var note: String? {
        switch status {
        case .done: nil
        case .processing: processingNote
        case .failed: "Nothing was taken."
        }
    }

    public var body: some View {
        scrollContent
            .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) { bar })
            .sensoryFeedback(.success, trigger: status, condition: Self.becameDone)
            .sensoryFeedback(.error, trigger: status, condition: Self.becameFailed)
            .onAppear {
                titleFocused = true
                AccessibilityNotification.Announcement(shownTitle).post()
            }
            .onChange(of: status) { _, _ in
                AccessibilityNotification.Announcement(shownTitle).post()
            }
    }

    private static func becameDone(_ old: MoveStatus, _ new: MoveStatus) -> Bool {
        old != MoveStatus.done && new == MoveStatus.done
    }

    private static func becameFailed(_ old: MoveStatus, _ new: MoveStatus) -> Bool {
        old != MoveStatus.failed && new == MoveStatus.failed
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReceiptSymbol(status: status)
                    .padding(.top, Spacing.space6)
                titleText
                    .padding(.top, Spacing.space4)
                if let amount {
                    MoneyText(amount, direction: amountDirection, style: .displayAmount, strikethrough: status == .failed)
                        .modifier(OptionalIdentifier(identifier: amountIdentifier))
                        .padding(.top, Spacing.space2)
                }
                VStack(spacing: 0) {
                    ForEach(rows + [DetailRow("Status", .status(status))]) { DetailRowView($0) }
                }
                .padding(.top, Spacing.space8)
                if let note {
                    noteText(note)
                }
                if let footnote, status != .failed {
                    noteText(footnote)
                        .modifier(OptionalIdentifier(identifier: footnoteIdentifier))
                }
            }
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.bottom, Spacing.space6)
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: status)
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: footnote)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var titleText: some View {
        Text(shownTitle)
            .textStyle(.title1)
            .foregroundStyle(Palette.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
    }

    private func noteText(_ note: String) -> some View {
        Text(note)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.space3)
            .transition(.opacity)
    }

    private var bar: some View {
        VStack(spacing: Spacing.space3) {
            if let secondaryTitle, let onSecondary, !dynamicTypeSize.isAccessibilitySize {
                MoolaButton(secondaryTitle, kind: .secondary, action: onSecondary)
            }
            MoolaButton("Done", action: onDone)
        }
    }
}

private struct ReviewStepPreview: View {
    private let rows: [DetailRow] = [
        DetailRow("From", .text("Balance")),
        DetailRow("To", .goal(name: "Emergency fund", emoji: "\u{2602}\u{FE0F}", colorKey: "jade")),
        DetailRow("Fee", .fee(.zero)),
    ]

    var body: some View {
        NavigationStack {
            ReviewStep(
                amount: Money(cents: 5_000),
                rows: rows,
                confirmTitle: "Confirm with Face ID",
                confirmSystemImage: "faceid",
                isConfirming: false,
                onConfirm: {},
                onEditAmount: {}
            )
        }
    }
}

private struct ReceiptStepPreview: View {
    private let rows: [DetailRow] = [DetailRow("From", .text("Balance")), DetailRow("Date", .text("Oct 24 at 5:00 PM"))]

    var body: some View {
        NavigationStack {
            ReceiptStep(
                status: .processing,
                title: "Moved to Emergency fund",
                amount: Money(cents: 5_000),
                rows: rows,
                secondaryTitle: "View goal",
                footnote: "This starts your weekly streak.",
                onDone: {},
                onSecondary: {}
            )
        }
    }
}

#Preview("Review") {
    ReviewStepPreview()
}

#Preview("Receipt") {
    ReceiptStepPreview()
}

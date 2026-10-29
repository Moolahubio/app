import APIClient
import Auth
import DesignSystem
import Domain
import Foundation
import Observation
import SwiftUI
import UIKit

// Feature-internal helpers shared by the Savings screens and sheets.

// MARK: - Feature events

/// Signals between Savings screens that live in different navigation stacks or
/// sheets: "goals changed, refresh" and one pending toast for the next screen
/// that appears (DESIGN.md v2 B3.12 "Goal created.", B3.7 "Goal deleted.").
@MainActor
@Observable
final class SavingsEvents {
    static let shared = SavingsEvents()

    enum ToastTarget: Hashable, Sendable {
        case goal(id: String)
        case savingsList
    }

    struct PendingToast: Hashable, Sendable {
        let target: ToastTarget
        let message: String
    }

    /// Bumped after every create, money move and delete.
    private(set) var revision = 0
    private(set) var pendingToast: PendingToast?

    /// After a create, a money move (or one whose outcome is unknown) and a
    /// delete: the Savings screens refetch, and Home, which shows the balance
    /// and the goals and may sit in another tab, is told to refresh (J0.1, J0.7).
    func goalsChanged() {
        revision &+= 1
        AppSignals.postMoneyMoved()
    }

    func queueToast(_ message: String, for target: ToastTarget) {
        pendingToast = PendingToast(target: target, message: message)
    }

    /// Hands the pending toast to `target` (once).
    func takeToast(for target: ToastTarget) -> String? {
        guard let pendingToast, pendingToast.target == target else { return nil }
        self.pendingToast = nil
        return pendingToast.message
    }
}

// MARK: - Reads

/// One Savings read (`GET /goals`, `GET /goals/{id}`, `GET /wallet`) for a
/// `RemoteResource`. Money moves never go through here.
func savingsRead<Value: Sendable>(_ read: @Sendable () async throws -> Value) async throws -> Value {
    #if DEBUG
    switch SavingsDebugReads.mode {
    case .slow:
        try await Task.sleep(for: .seconds(SavingsDebugReads.slowDelaySeconds))
    case .offline:
        throw APIError.notConnected
    case nil:
        break
    }
    #endif
    return try await read()
}

#if DEBUG
/// Debug builds only: lets a UI test reach the Savings loading and error
/// states (B3.3, B3.5, B3.6, B3.13, B3.15, B3.18, B3.19), which the live dev
/// backend never produces on demand. `-mh-savings-slow-reads` holds every
/// Savings read for 20 seconds (skeletons); `-mh-savings-offline-reads`
/// fails them as "not connected" before they leave (error states, and cached
/// data with a failed refresh). Nothing is invented: a read either waits or
/// fails, and money moves are untouched.
enum SavingsDebugReads {
    enum Mode: Sendable {
        case slow
        case offline
    }

    static let slowDelaySeconds = 20

    static var mode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-mh-savings-offline-reads") { return .offline }
        if arguments.contains("-mh-savings-slow-reads") { return .slow }
        return nil
    }
}
#endif

// MARK: - Copy

/// Copy from DESIGN.md v2 B3, J2 to J4 and W9.1 that needs a value or a plural.
enum SavingsCopy {
    static let loadingGoals = "Loading your goals\u{2026}"
    static let loadingGoal = "Loading goal\u{2026}"
    static let loadingBalance = "Loading your balance\u{2026}"
    static let cancelledNothingTaken = "Cancelled. Nothing was taken."
    static let notEnoughAvailable = "You don't have enough available for that. Add money or choose a smaller amount."
    static let moreThanGoalHas = "That's more than this goal has."
    static let mayBeOutOfDate = "May be out of date"

    /// "Across 1 goal" / "Across 3 goals".
    static func acrossGoals(_ count: Int) -> String {
        count == 1 ? "Across 1 goal" : "Across \(count) goals"
    }

    /// "1 day" / "3 weeks" / "2 months".
    static func periods(_ count: Int, _ frequency: GoalFrequency) -> String {
        let unit: String
        switch frequency {
        case .daily: unit = count == 1 ? "day" : "days"
        case .weekly: unit = count == 1 ? "week" : "weeks"
        case .monthly: unit = count == 1 ? "month" : "months"
        }
        return "\(count) \(unit)"
    }

    /// "today" / "this week" / "this month".
    static func thisPeriod(_ frequency: GoalFrequency) -> String {
        switch frequency {
        case .daily: "today"
        case .weekly: "this week"
        case .monthly: "this month"
        }
    }

    /// Plan preview (B3.8, W9.1).
    static func planPreview(_ plan: ContributionPlan.GoalPlan) -> String {
        let first = Money(cents: plan.firstCents).formatted()
        let last = Money(cents: plan.lastCents).formatted()
        switch plan.frequency {
        case .daily:
            return "Start at \(first) today and build up to \(last) over \(SavingsCopy.periods(plan.periods, .daily))."
        case .weekly:
            return "Start at \(first) this week and build up to \(last) over \(SavingsCopy.periods(plan.periods, .weekly))."
        case .monthly:
            return "Start at \(first) this month and build up to \(last) over \(SavingsCopy.periods(plan.periods, .monthly))."
        }
    }

    /// Delete goal consequence (B3.26, J4).
    static func deleteBody(saved: Money, fee: FeeRate) -> String {
        if !saved.isPositive {
            return "This permanently closes the goal."
        }
        if fee.isZero {
            return "This moves the full \(saved.formatted()) back to your balance and closes the goal."
        }
        return "This moves the full \(saved.formatted()) back to your balance, minus the \(fee.percentText) fee, and closes the goal."
    }

    /// "Enter at least $1.00." (W10.5).
    static func enterAtLeast(_ minimum: Money) -> String {
        "Enter at least \(minimum.formatted())."
    }
}

// MARK: - Dates

enum SavingsDates {
    /// Whole periods between two instants by frequency (daily: whole days,
    /// weekly: whole days ÷ 7, monthly: whole calendar months), DESIGN.md v2
    /// W5 ("left" clause) and W9.1. The receipts' and history's date and time
    /// style lives in DesignSystem as `MoolaDates.dateAndTime` (W5, U5).
    static func wholePeriods(from start: Date, to end: Date, frequency: GoalFrequency, calendar: Calendar = .current) -> Int {
        switch frequency {
        case .daily:
            return calendar.dateComponents([.day], from: start, to: end).day ?? 0
        case .weekly:
            return (calendar.dateComponents([.day], from: start, to: end).day ?? 0) / 7
        case .monthly:
            return calendar.dateComponents([.month], from: start, to: end).month ?? 0
        }
    }
}

// MARK: - Money-move failures

/// How a failed money move is shown (DESIGN.md v2 J0.7, W6).
struct MoveFailure: Equatable {
    let title: String?
    let message: String
    /// The move may have happened. Never retry; send the user to Activity.
    let isUncertain: Bool

    /// Nil for errors that show nothing (`.cancelled`, `.sessionExpired`: the
    /// root swaps to Sign in).
    init?(_ error: APIError) {
        switch error {
        case .cancelled, .sessionExpired:
            return nil
        case .noResponse, .invalidResponse:
            // No response, or a response we couldn't read (a 2xx with an
            // unexpected body means the move probably happened): DESIGN.md
            // W6 "any error after the request left".
            title = nil
            isUncertain = true
            message = APIError.Copy.uncertainMoneyMove
            return
        case .rejected(let status, let message):
            // A clear refusal (J0.7): a 4xx with the server's message, a 403 or
            // a 409. "Invalid request" (400) is "Something went wrong." alone.
            let hasMessage = message.map { !$0.isEmpty && $0 != "Invalid request" } ?? false
            title = hasMessage || status == 403 || status == 409 ? APIError.Copy.moneyMoveRefusedTitle : nil
            isUncertain = false
        case .rateLimited(let message):
            // A 429 with a message is a refusal; without one, "Too many tries." alone.
            title = (message?.isEmpty == false) ? APIError.Copy.moneyMoveRefusedTitle : nil
            isUncertain = false
        default:
            title = nil
            isUncertain = false
        }
        message = error.message(for: .moneyMove)
    }
}

// MARK: - Receipt status (DESIGN.md v2 J0.6)

/// The Activity item a money move should produce: its `type` and the amount
/// signed relative to the balance.
struct ExpectedActivity: Hashable, Sendable {
    let type: String
    let amountCents: Int64
}

/// Decides Done / Processing for a receipt only by matching `GET /activity`:
/// fetches `?limit=10` at 0s, 1s and 3s and takes the newest item with the
/// expected type and signed amount created no earlier than 5 seconds before
/// the request was sent. Nothing found: stays Processing.
@MainActor
@Observable
final class ReceiptStatusTracker {
    private(set) var status: MoveStatus = .processing
    /// `createdAt` of the matched Activity item.
    private(set) var matchedAt: Date?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let expected: ExpectedActivity
    @ObservationIgnored private let sentAt: Date
    @ObservationIgnored private var hasStarted = false

    init(api: APIClient, expected: ExpectedActivity, sentAt: Date) {
        self.api = api
        self.expected = expected
        self.sentAt = sentAt
    }

    func run() async {
        guard !hasStarted else { return }
        hasStarted = true
        let waits: [Duration] = [.zero, .seconds(1), .seconds(2)]
        let cutoff = sentAt.addingTimeInterval(-5)
        for wait in waits {
            if wait > .zero {
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    return
                }
            }
            let items: [ActivityItem]
            do throws(APIError) {
                items = try await api.send(API.Activity.list(limit: 10))
            } catch {
                if error == .cancelled { return }
                continue
            }
            let match = items
                .filter { $0.type == expected.type && $0.amountCents == expected.amountCents && $0.createdAt >= cutoff }
                .max { $0.createdAt < $1.createdAt }
            if let match {
                status = match.status
                matchedAt = match.createdAt
                if match.status != .processing { return }
            }
        }
    }
}

// MARK: - Step-up ("Confirm it's you", DESIGN.md v2 J0.4)

/// Password (and authenticator code when 2FA is on) for one step-up request.
/// Never stored beyond the sheet; cleared after every request.
@MainActor
@Observable
final class StepUpState {
    var password = ""
    var code = ""
    /// Nil while `GET /security/2fa` loads.
    private(set) var needsCode: Bool?
    private(set) var statusError: APIError?
    /// The server's 401 message ("Your password is incorrect."), inline.
    var fieldError: String?

    func loadStatus(api: APIClient) async {
        statusError = nil
        do throws(APIError) {
            let status = try await api.send(API.Security.twoFactorStatus())
            needsCode = status.enabled
        } catch {
            if error != .cancelled { statusError = error }
        }
    }

    var canSubmit: Bool {
        guard let needsCode, !password.isEmpty else { return false }
        return needsCode ? Validation.isSixDigitCode(code.trimmingCharacters(in: .whitespaces)) : true
    }

    /// The proof for one request. Call `clear()` right after sending.
    var proof: StepUpProof {
        StepUpProof(
            currentPassword: Secret(password),
            twoFactorCode: needsCode == true ? Secret(code.trimmingCharacters(in: .whitespaces)) : nil
        )
    }

    func clear() {
        password = ""
        code = ""
    }
}

// MARK: - Keyboard

@MainActor
enum SavingsKeyboard {
    /// Ends text editing before pushing a step that has its own keypad, so the
    /// keyboard doesn't come back over the form when the user returns.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Sheet chrome

/// Close on a Savings sheet step (DESIGN.md v2 B3.1 item 4, A4.4): the
/// DesignSystem `SheetCloseButton` with the identifier `savings.sheet.close`,
/// top-leading (`.cancellationAction`) on a sheet's first step and
/// top-trailing (`.topBarTrailing`, never `.confirmationAction`) on a pushed
/// step, where the system Back sits top-leading. Where Close asks first, the
/// system "Discard this?" dialog is attached to the button itself, so the
/// iOS 26 popover points at it (B3.10). Hidden while a request is in flight.
struct SavingsSheetClose: ViewModifier {
    let asksFirst: Bool
    let isHidden: Bool
    let isRootStep: Bool
    let close: () -> Void

    @State private var confirmsDiscard = false

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isHidden {
                    ToolbarItem(placement: isRootStep ? .cancellationAction : .topBarTrailing) {
                        SheetCloseButton(identifier: "savings.sheet.close") {
                            if asksFirst {
                                confirmsDiscard = true
                            } else {
                                close()
                            }
                        }
                        .confirmationDialog("Discard this?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                            Button("Discard", role: .destructive) { close() }
                            Button("Keep editing", role: .cancel) {}
                        }
                    }
                }
            }
    }
}

extension View {
    /// Close for this step (B3.1 item 4). `asksFirst`: "Discard this?" first.
    func savingsCloseButton(asksFirst: Bool, isHidden: Bool = false, isRootStep: Bool, close: @escaping () -> Void) -> some View {
        modifier(SavingsSheetClose(asksFirst: asksFirst, isHidden: isHidden, isRootStep: isRootStep, close: close))
    }

    /// Every Savings sheet (B3.1 item 3, A4.4): `SheetChrome([.large])`, which
    /// gives the ink tint and paints `sheetCanvas` only on iOS 17 and 18 (on
    /// iOS 26 the system sheet shows and content paints no background).
    /// Swipe-down is blocked where Close asks and while a request is in
    /// flight, because a swipe cannot ask (ruling 23).
    func savingsSheetChrome(blocksSwipeDown: Bool) -> some View {
        sheetChrome([.large])
            .interactiveDismissDisabled(blocksSwipeDown)
    }
}

/// A sheet step's title (B3.1 item 5, A3.2 task sheet): `title1`, 8 pt below
/// the sheet toolbar, a header that takes VoiceOver focus on appear; an
/// optional subtitle that is a name (`body` `textSecondary`) 4 pt below, or
/// its skeleton while the goal loads (B3.19: 122 × 11.3).
struct SheetStepTitle: View {
    let title: String
    let subtitle: String?
    let subtitleIsLoading: Bool

    @AccessibilityFocusState private var isFocused: Bool

    init(_ title: String, subtitle: String? = nil, subtitleIsLoading: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsLoading = subtitleIsLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(title)
                .textStyle(.title1)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isFocused)
            if let subtitle {
                Text(subtitle)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if subtitleIsLoading {
                LoadingPlaceholder(label: SavingsCopy.loadingGoal) {
                    // On the `body` line it stands in for.
                    SkeletonTextLine(.body, leadingWidth: 122)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Spacing.space2)
        .onAppear { isFocused = true }
    }
}


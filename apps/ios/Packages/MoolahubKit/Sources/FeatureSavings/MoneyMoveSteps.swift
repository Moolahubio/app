import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

// Steps shared by Create goal (target amount), Move to goal, Move to balance
// and Delete goal (DESIGN.md v2 Part J, B3.9, B3.19 to B3.27).

/// An amount step (J0.2, B3.9, B3.19, B3.22): the step title (`title1`) and
/// an optional name subtitle, 24 pt, `AmountEntry` (display, context line,
/// reserved validation slot, presets, 56 pt keypad), and the main button
/// pinned at the bottom (A4.4, A8.30). No reason line (A9.9 exception: the
/// empty "$0" or the red validation line is the reason). At accessibility
/// sizes the keypad scrolls and the button stays pinned.
struct AmountStepView: View {
    let title: String
    let subtitle: String?
    var subtitleIsLoading = false
    @Binding var buffer: AmountEntryBuffer
    let context: String?
    /// While the context's figure loads: the skeleton's VoiceOver label (B3.19).
    var contextLoadingLabel: String? = nil
    let presets: [AmountPreset]
    let maximum: Money?
    let validationMessage: String?
    let isEnabled: Bool
    let buttonTitle: String
    let canContinue: Bool
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SheetStepTitle(title, subtitle: subtitle, subtitleIsLoading: subtitleIsLoading)
                AmountEntry(
                    buffer: $buffer,
                    context: context,
                    presets: presets,
                    maximum: maximum,
                    validationMessage: validationMessage,
                    isEnabled: isEnabled,
                    contextLoadingLabel: contextLoadingLabel
                )
                .padding(.top, Spacing.space6)
            }
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        // On a home-button iPhone (375 × 667) the keypad's last rows rest
        // under the bar (ruling 5 accepts the scroll): a hard edge, so they
        // don't show through above and below the button.
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet, hardEdge: PinnedBarMetrics.amountStepHardEdge) {
            MoolaButton(buttonTitle, action: onContinue)
                .disabled(!canContinue)
                .accessibilityIdentifier("savings.amount.continue")
        })
    }
}

/// Validation under the amount display (A8.12, W10.5): empty or zero says
/// nothing (the disabled button and the empty "$0" are the reason); below
/// the minimum and above the maximum say why.
enum AmountValidation {
    static func message(for amount: Money?, minimum: Money, maximum: Money?, aboveMaximum: String?) -> String? {
        guard let amount, amount.isPositive else { return nil }
        if amount < minimum { return SavingsCopy.enterAtLeast(minimum) }
        if let maximum, amount > maximum { return aboveMaximum }
        return nil
    }

    static func isValid(_ amount: Money?, minimum: Money, maximum: Money?) -> Bool {
        guard let amount, amount.isPositive, amount >= minimum else { return false }
        if let maximum, amount > maximum { return false }
        return true
    }
}

/// The Review step (J0.3, A8.15, B3.20, B3.23): DesignSystem's `ReviewStep`
/// with a failed move mapped onto its error banner (J0.7: a refusal's title
/// "Didn't go through. Nothing was taken." over the server's message, or the
/// uncertain-outcome message with "View activity", which also disables the
/// confirm and hides Back for good: never retried).
struct MoveReviewView: View {
    let amount: Money
    let rows: [DetailRow]
    let footnote: String?
    let confirmTitle: String
    let confirmSystemImage: String?
    let isConfirming: Bool
    let note: String?
    let failure: MoveFailure?
    let onConfirm: () -> Void
    let onEditAmount: () -> Void
    let onViewActivity: () -> Void

    var body: some View {
        let isUncertain = failure?.isUncertain == true
        ReviewStep(
            amount: amount,
            rows: rows,
            footnote: footnote,
            confirmTitle: confirmTitle,
            confirmSystemImage: confirmSystemImage,
            isConfirming: isConfirming,
            note: note,
            errorTitle: failure?.title,
            errorMessage: failure?.message,
            errorActionTitle: isUncertain ? "View activity" : nil,
            onErrorAction: isUncertain ? onViewActivity : nil,
            isConfirmDisabled: isUncertain,
            blocksGoingBack: isUncertain,
            identifierPrefix: "savings.review",
            onConfirm: onConfirm,
            onEditAmount: onEditAmount
        )
    }
}

/// A failed money move or delete (J0.7, A8.23): the refusal title over the
/// server's message, or the uncertain-outcome copy with "View activity".
struct MoveFailureBanner: View {
    let failure: MoveFailure
    let onViewActivity: () -> Void

    var body: some View {
        Group {
            if failure.isUncertain {
                ErrorBanner(failure.message, title: failure.title, retryTitle: "View activity", retry: onViewActivity)
            } else {
                ErrorBanner(failure.message, title: failure.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// The pinned bar of a step-up step (Move to balance's "Confirm it's you",
/// Delete goal; B3.24, B3.26): the failure banner 12 pt above the main
/// button, no reason slot (A9.9 exception: the instruction sentence names
/// every input). At accessibility sizes the bar holds only the button and the
/// banner moves into the scroll content (A8.30); `StepUpScrollFooter` draws it.
struct StepUpBar<MainButton: View>: View {
    let failure: MoveFailure?
    let onViewActivity: () -> Void
    let button: MainButton

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(failure: MoveFailure?, onViewActivity: @escaping () -> Void, @ViewBuilder button: () -> MainButton) {
        self.failure = failure
        self.onViewActivity = onViewActivity
        self.button = button()
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure, !dynamicTypeSize.isAccessibilitySize {
                MoveFailureBanner(failure: failure, onViewActivity: onViewActivity)
                    .padding(.bottom, Spacing.space3)
            }
            button
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: failure)
    }
}

/// The step-up failure banner in the scroll content at accessibility sizes
/// (A8.30), under the last field.
struct StepUpScrollFooter: View {
    let failure: MoveFailure?
    let onViewActivity: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let failure, dynamicTypeSize.isAccessibilitySize {
            MoveFailureBanner(failure: failure, onViewActivity: onViewActivity)
                .padding(.top, Spacing.space6)
        }
    }
}

/// "Confirm it's you" as its own step (Move to balance, J3 step 3, B3.24,
/// A8.18): title (`title1`, focus on appear), 8 pt, the instruction, 24 pt,
/// "Password" (and "Authenticator code" with two-factor on), the server's 401
/// message under the fields; a failed `GET /security/2fa` shows a banner with
/// "Try again" 16 pt below. Pinned: the failure banner and "Move to balance"
/// (loading "Confirming…"), disabled until a password (and a 6-digit code
/// when required). Back and Close hide while submitting and after an
/// uncertain failure.
struct StepUpStepView: View {
    @Bindable var stepUp: StepUpState
    let actionTitle: String
    let isWorking: Bool
    let failure: MoveFailure?
    let onSubmit: () -> Void
    let onRetryStatus: () -> Void
    let onViewActivity: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetStepTitle("Confirm it's you")
                StepUpFields(
                    password: $stepUp.password,
                    code: $stepUp.code,
                    needsCode: stepUp.needsCode,
                    error: stepUp.fieldError,
                    showsTitle: false
                )
                .padding(.top, Spacing.space2)
                if let statusError = stepUp.statusError {
                    ErrorBanner(statusError.message(for: .screen), retry: onRetryStatus)
                        .padding(.top, Spacing.space4)
                }
                StepUpScrollFooter(failure: failure, onViewActivity: onViewActivity)
            }
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            StepUpBar(failure: failure, onViewActivity: onViewActivity) {
                MoolaButton(actionTitle, loadingTitle: "Confirming\u{2026}", isLoading: isWorking, action: onSubmit)
                    .disabled(!stepUp.canSubmit || failure?.isUncertain == true)
                    .accessibilityIdentifier("savings.stepUp.submit")
            }
        })
        .navigationBarBackButtonHidden(isWorking || failure?.isUncertain == true)
    }
}

/// A flow receipt (J0.6, A8.16, B3.21, B3.25, B3.27) whose status comes only
/// from matching `GET /activity` (`ReceiptStatusTracker`), never a guess. The
/// caller's rows, then "Date" (the matched item's `createdAt`, else the send
/// time, in the W5 date-and-time style) and "Status". No Back, no Close:
/// "Done" is the exit.
struct TrackedReceiptView: View {
    let title: String
    let amount: Money
    /// Rows before "Date" and "Status".
    let rows: [DetailRow]
    let sentAt: Date
    let tracker: ReceiptStatusTracker
    let secondaryTitle: String?
    let onDone: () -> Void
    let onSecondary: (() -> Void)?

    var body: some View {
        ReceiptStep(
            status: tracker.status,
            title: title,
            amount: amount,
            rows: rows + [DetailRow("Date", .text(MoolaDates.dateAndTime(tracker.matchedAt ?? sentAt)))],
            secondaryTitle: secondaryTitle,
            onDone: onDone,
            onSecondary: onSecondary
        )
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .task { await tracker.run() }
    }
}

/// The confirm button from the device (J0.3 item 2): "Confirm with Face ID" /
/// Touch ID / Optic ID / passcode with its leading symbol, or "Confirm" with
/// no symbol when the device has no passcode.
struct ConfirmButtonSpec {
    let title: String
    let systemImage: String?

    init(_ kind: BiometryKind) {
        title = kind.confirmTitle
        systemImage = kind.isAvailable ? kind.symbolName : nil
    }
}

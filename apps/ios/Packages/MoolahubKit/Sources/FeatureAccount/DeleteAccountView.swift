import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Delete account (account.md B5.16, B5.17; SPEC §4.3): what deletion removes
/// and keeps, then the conditions the server enforces, checked before any
/// password is asked. Three parallel, uncached reads (`GET /dashboard/summary`,
/// `GET /circles`, `GET /goals`) run when the screen appears, each time it
/// reappears and on pull to refresh; a cached "nothing in the way" could send
/// the person to step-up for nothing. Only unmet conditions draw a row, in the
/// server's order; the rows' words come from Domain's `DeleteAccountPrecheck`.
/// When nothing is in the way, "Delete account" opens the confirmation, then
/// the step-up sheet, then `DELETE /account`.
struct DeleteAccountView: View {
    let services: AppServices

    /// The last finished check; nil before the first one lands.
    @State private var outcome: DeleteAccountPrecheck.Outcome?
    /// Why the last check failed (`.error`), for the ErrorState's body.
    @State private var readError: APIError?
    @State private var isChecking = false
    /// Only the newest check's answer is applied.
    @State private var checkGeneration = 0
    /// Set when `DELETE /account` answered 409; the banner shows once the
    /// re-check it starts has landed, and clears when the screen is left.
    @State private var refusedByServer = false
    @State private var confirmsDelete = false
    /// The dialog's choice, presented once the dialog has gone (B5.14 note).
    @State private var pendingStepUp = false
    @State private var sheet: AccountSheet?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    private var isClear: Bool { outcome == .clear && !isChecking }

    /// W10.4-acc1 while checking; W10.4-acc2 while something is in the way;
    /// nothing once the button is enabled (the slot stays, A9.9).
    private var reason: String? {
        if isChecking || outcome == nil { return "Checking your account\u{2026}" }
        if case .blocked = outcome { return "Clear the items above to continue." }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let banner = refusalBanner {
                    ErrorBanner(banner)
                        .accessibilityIdentifier("account.delete.banner")
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.bottom, AccountLayout.statusToContent)
                        .transition(.opacity)
                }

                explanation

                if outcome == .error, let readError {
                    ErrorState(
                        title: "We couldn't check your account",
                        message: Self.readFailureMessage(readError),
                        isRetrying: isChecking
                    ) {
                        Task { await check() }
                    }
                    .accessibilityIdentifier("account.delete.error")
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.sectionGap)
                    .transition(.opacity)
                } else {
                    let blockers = outcome?.blockers ?? []
                    if !blockers.isEmpty {
                        blockerList(blockers)
                            .transition(.opacity)
                    }
                    deleteButton
                        .padding(.top, Spacing.space8)
                }
            }
            .padding(.top, AccountLayout.pushedTop)
            .padding(.bottom, Spacing.space8)
            .animation(standardAnimation, value: outcome)
            .animation(standardAnimation, value: refusalBanner)
        }
        .moolaCanvas()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // The reason line is the loading label (W8): said once as the
            // re-check starts.
            AccessibilityNotification.Announcement("Checking your account\u{2026}").post()
            await check()
        }
        .task { await check() }
        .onDisappear { refusedByServer = false }
        .onChange(of: confirmsDelete) { _, isShown in
            guard !isShown, pendingStepUp else { return }
            pendingStepUp = false
            sheet = .stepUp(.delete)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .stepUp(let action):
                AccountStepUpSheet(services: services, action: action) {
                    // B5.16 "After a 409": re-check, then say what was found.
                    refusedByServer = true
                    Task { await check() }
                }
            }
        }
    }

    // MARK: Explanation

    /// W10.9-acc5 (`body` `textPrimary`) and W10.9-acc6 (`textSecondary`),
    /// 8 pt apart.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("Deleting your account removes your name, username, email, date of birth and sign-in details, and signs you out on every device.")
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityIdentifier("account.delete.intro")
            Text("Records of your past moves are kept, but not your name. Group members will see \"Deleted member\" instead.")
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
    }

    // MARK: Blockers

    /// "Before you can delete your account" at `sectionGap`, then one row per
    /// unmet condition, 4 pt under the heading (the rows' own 12 pt padding
    /// makes `headingToContent` to the first title).
    private func blockerList(_ blockers: [DeleteAccountPrecheck.Blocker]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Before you can delete your account")
                .padding(.horizontal, Spacing.screenGutter)
                .accessibilityIdentifier("account.delete.blockers")
                .padding(.bottom, Spacing.space1)
            ForEach(blockers, id: \.self) { blocker in
                blockerRow(blocker)
            }
        }
        .padding(.top, Spacing.sectionGap)
    }

    /// The balance is a display row (its value a `MoneyText`, no figure when
    /// unknown); groups and goals are navigation rows that switch tabs, their
    /// counts tabular (`.monospacedDigit()`, B5.16; their titles and sub-lines
    /// hold no digits). Each speaks its sub-line in its value (D-14).
    @ViewBuilder
    private func blockerRow(_ blocker: DeleteAccountPrecheck.Blocker) -> some View {
        switch blocker {
        case .balance(let total):
            SettingsValueRow(title: blocker.title, subtitle: blocker.subline) {
                MoneyText(total)
            }
            .accessibilityLabel(blocker.title)
            .accessibilityValue(blocker.accessibilityValue)
            .accessibilityIdentifier("account.delete.blocker.balance")
        case .balanceUnknown:
            SettingsValueRow(title: blocker.title, subtitle: blocker.subline) {
                EmptyView()
            }
            .accessibilityLabel(blocker.title)
            .accessibilityValue(blocker.accessibilityValue)
            .accessibilityIdentifier("account.delete.blocker.balance")
        case .groups:
            SettingsRow(symbol: nil, title: blocker.title, subtitle: blocker.subline, value: blocker.value) {
                services.navigator.select(.groups)
            }
            .monospacedDigit()
            .accessibilityLabel(blocker.title)
            .accessibilityValue(blocker.accessibilityValue)
            .accessibilityHint("Opens Groups.")
            .accessibilityIdentifier("account.delete.blocker.groups")
        case .goals:
            SettingsRow(symbol: nil, title: blocker.title, subtitle: blocker.subline, value: blocker.value) {
                services.navigator.select(.savings)
            }
            .monospacedDigit()
            .accessibilityLabel(blocker.title)
            .accessibilityValue(blocker.accessibilityValue)
            .accessibilityHint("Opens Savings.")
            .accessibilityIdentifier("account.delete.blocker.goals")
        }
    }

    // MARK: Delete button and its dialog

    /// Destructive `MoolaButton`, enabled only when nothing is in the way;
    /// the reserved reason slot 8 pt under it (A9.9). B5.17's dialog is
    /// attached to the button.
    private var deleteButton: some View {
        VStack(spacing: Spacing.space2) {
            MoolaButton("Delete account", kind: .destructive) {
                confirmsDelete = true
            }
            .disabled(!isClear)
            .accessibilityHint(reason ?? "")
            .accessibilityIdentifier("account.delete.start")
            .confirmationDialog("Delete your account?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    pendingStepUp = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            DisabledReasonLine(text: reason ?? "Clear the items above to continue.", isShown: reason != nil)
                .accessibilityIdentifier("account.delete.reason")
        }
        .padding(.horizontal, Spacing.screenGutter)
    }

    // MARK: Checking

    /// After a 409: W10.3-acc1 when the re-check finds something in the way,
    /// W10.3-acc2 when it finds nothing (ledger and display disagree, or
    /// something was still settling). Nothing while the re-check runs, and
    /// nothing when it fails: the ErrorState alone says so (B5.16 gives no
    /// banner for that case), and "Try again" brings the banner back with
    /// what it finds.
    private var refusalBanner: String? {
        guard refusedByServer, !isChecking, let outcome, outcome != .error else { return nil }
        if case .blocked = outcome {
            return "We couldn't delete your account. Something below still needs to be cleared."
        }
        return "We couldn't delete your account yet. Please try again in a few minutes."
    }

    /// The ErrorState's body (W6): the offline sentence, else the screen one.
    private static func readFailureMessage(_ error: APIError) -> String {
        error == .notConnected ? APIError.Copy.notConnected : APIError.Copy.screenFailed
    }

    /// Runs the three reads in parallel. The last result stays drawn (and the
    /// button disabled) until the new one lands; a read cancelled because the
    /// screen went away changes nothing; a failed read is an error, never a
    /// clear result.
    private func check() async {
        checkGeneration &+= 1
        let generation = checkGeneration
        isChecking = true
        let api = services.api
        async let summary = Self.read(API.Dashboard.summary(), api: api)
        async let circles = Self.read(API.Groups.list(), api: api)
        async let goals = Self.read(API.Goals.list(), api: api)
        let results = await (summary, circles, goals)
        guard generation == checkGeneration else { return }
        defer { isChecking = false }
        let failures = [Self.failure(results.0), Self.failure(results.1), Self.failure(results.2)].compactMap { $0 }
        guard !failures.contains(.cancelled) else { return }
        readError = failures.first
        outcome = DeleteAccountPrecheck.outcome(summary: results.0, circles: results.1, goals: results.2)
    }

    private nonisolated static func read<Response>(
        _ request: APIRequest<Response>,
        api: APIClient
    ) async -> Result<Response, APIError> {
        do throws(APIError) {
            return .success(try await api.send(request))
        } catch {
            return .failure(error)
        }
    }

    private static func failure<Value>(_ result: Result<Value, APIError>) -> APIError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

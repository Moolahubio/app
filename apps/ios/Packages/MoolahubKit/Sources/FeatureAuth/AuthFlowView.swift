import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Signed-out flow root (DESIGN.md v2 B1.13 to B1.20). AppFeature shows it
/// whenever `SessionStore.state` is `.signedOut`; when sign-in completes the
/// session state changes and AppFeature swaps to the tabs. Keep this name and
/// initializer.
///
/// Welcome → Sign in (→ Two-factor / Verify email / Forgot password → Reset
/// password) or Create account → Verify email (→ Two-factor).
public struct AuthFlowView: View {
    private let services: AppServices
    @State private var path: [AuthRoute]
    /// A message Sign in shows on arrival (an expired two-factor session).
    @State private var signInNotice: String?
    /// After a deactivation or deletion on this device: the toast Welcome
    /// shows once (B1.13 amended), then nil.
    @State private var closedAccountToast: ClosedAccountToast?
    @State private var toast: String?

    public init(services: AppServices) {
        self.services = services
        // Arriving after an expiry or a reset goes straight to Sign in with a
        // banner; after a sign-out or a closed account, Welcome.
        switch SignedOutArrival.route(for: services.session.signedOutReason) {
        case .signIn:
            _path = State(initialValue: [.signIn])
        case .welcome(let toast):
            _path = State(initialValue: [])
            _closedAccountToast = State(initialValue: toast)
        }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            WelcomeView(services: services, path: $path)
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .signIn:
                        SignInView(services: services, path: $path, notice: $signInNotice)
                    case .createAccount:
                        SignUpView(services: services, path: $path)
                    case .verifyEmail(let email):
                        VerifyEmailView(services: services, path: $path, email: email)
                    case .twoFactor(let challengeID):
                        TwoFactorView(services: services, path: $path, signInNotice: $signInNotice, challengeID: challengeID)
                    case .forgotPassword(let email):
                        ForgotPasswordView(services: services, path: $path, email: email)
                    case .resetPassword(let email):
                        ResetPasswordView(services: services, path: $path, email: email)
                    }
                }
        }
        // Ink for the back button, links and the date picker (A1.6, B1.0.4).
        .tint(Palette.ctaBackground)
        // The one signed-out toast host (account.md §8, §13.4): "Account
        // deactivated." or "Account deleted.", once, after the root's
        // cross-fade. The reason does not survive a relaunch, so neither does
        // the toast.
        .toast($toast)
        .task {
            guard let closed = closedAccountToast else { return }
            closedAccountToast = nil
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            toast = Self.words(for: closed)
        }
    }

    /// W10.6-acc1 and W10.6-acc2 (Auth holds no words, D-43).
    static func words(for toast: ClosedAccountToast) -> String {
        switch toast {
        case .deactivated: "Account deactivated."
        case .deleted: "Account deleted."
        }
    }
}

/// Screens inside the signed-out flow.
enum AuthRoute: Hashable {
    case signIn
    case createAccount
    case verifyEmail(email: String)
    case twoFactor(challengeID: String)
    /// `email`: Sign in's email when it is valid, else "" (A14).
    case forgotPassword(email: String)
    case resetPassword(email: String)
}

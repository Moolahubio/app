import Domain
import Foundation

/// The shared endpoint catalog, one function per route the iOS app uses,
/// mirroring lib/api-spec/openapi.yaml. Features call
/// `try await services.api.send(API.Goals.list())`. A feature that needs a
/// route not listed here declares it locally:
///
///     let request = APIRequest<OkResponse>.post("/notifications/read-all")
public enum API {
    public enum Health {
        /// `GET /healthz`
        public static func check() -> APIRequest<HealthStatus> {
            .get("/healthz", authentication: .none)
        }
    }

    public enum Auth {
        /// `POST /auth/login` → signed in, 2FA challenge, or verify email.
        public static func login(_ input: LoginInput) -> APIRequest<LoginResult> {
            .post("/auth/login", body: input, authentication: .none)
        }

        /// `POST /auth/register` → verification code sent.
        public static func register(_ input: RegisterInput) -> APIRequest<EmailVerificationRequired> {
            .post("/auth/register", body: input, authentication: .none)
        }

        /// `POST /auth/verify-email` → signed in (or 2FA challenge).
        public static func verifyEmail(_ input: VerifyEmailInput) -> APIRequest<LoginResult> {
            .post("/auth/verify-email", body: input, authentication: .none)
        }

        /// `POST /auth/resend-code`
        public static func resendCode(email: String) -> APIRequest<OkResponse> {
            .post("/auth/resend-code", body: EmailInput(email: email), authentication: .none)
        }

        /// `POST /auth/2fa/login`
        public static func twoFactorLogin(_ input: TwoFactorLoginInput) -> APIRequest<TwoFactorLoginResult> {
            .post("/auth/2fa/login", body: input, authentication: .none)
        }

        /// `POST /auth/forgot-password` (always ok; never reveals accounts).
        public static func forgotPassword(email: String) -> APIRequest<OkResponse> {
            .post("/auth/forgot-password", body: EmailInput(email: email), authentication: .none)
        }

        /// `POST /auth/reset-password`
        public static func resetPassword(_ input: ResetPasswordInput) -> APIRequest<OkResponse> {
            .post("/auth/reset-password", body: input, authentication: .none)
        }

        /// `GET /auth/username-available?username=`
        public static func usernameAvailable(_ username: String) -> APIRequest<UsernameAvailability> {
            .get("/auth/username-available", query: [URLQueryItem(name: "username", value: username)], authentication: .none)
        }

        /// `GET /auth/me`
        public static func me() -> APIRequest<AuthUser> {
            .get("/auth/me")
        }

        /// `POST /auth/logout` (deletes the server session for this token).
        public static func logout() -> APIRequest<OkResponse> {
            var request = APIRequest<OkResponse>.post("/auth/logout")
            request.timeout = 5
            return request
        }

        /// `POST /auth/password`. A 401 is a wrong password, shown inline.
        public static func changePassword(_ input: ChangePasswordInput) -> APIRequest<OkResponse> {
            .post("/auth/password", body: input)
        }
    }

    public enum Security {
        /// `GET /security/2fa`
        public static func twoFactorStatus() -> APIRequest<TwoFactorStatus> {
            .get("/security/2fa")
        }
    }

    public enum Dashboard {
        /// `GET /dashboard/summary`
        public static func summary() -> APIRequest<DashboardSummary> {
            .get("/dashboard/summary")
        }
    }

    public enum Wallet {
        /// `GET /wallet`
        public static func info() -> APIRequest<WalletInfo> {
            .get("/wallet")
        }

        #if DEBUG
        /// `POST /wallet/deposit`: dev-build test money (max $1,000.00).
        /// Money move: never retried. Debug builds only.
        public static func addTestMoney(_ amount: Money) -> APIRequest<OkResponse> {
            .post("/wallet/deposit", body: AmountInput(amount: amount))
        }
        #endif
    }

    public enum Goals {
        /// `GET /goals`
        public static func list() -> APIRequest<[Goal]> {
            .get("/goals")
        }

        /// `GET /goals/{id}` (includes `history`).
        public static func get(_ id: String) -> APIRequest<Goal> {
            .get("/goals/\(id.pathSegment)")
        }

        /// `POST /goals`
        public static func create(_ input: GoalInput) -> APIRequest<Goal> {
            .post("/goals", body: input)
        }

        /// `POST /goals/{id}/allocate`: Move to goal. Money move.
        public static func allocate(goalID: String, amount: Money) -> APIRequest<OkResponse> {
            .post("/goals/\(goalID.pathSegment)/allocate", body: AmountInput(amount: amount))
        }

        /// `POST /goals/{id}/release`: Move to balance (step-up). Money move.
        public static func release(goalID: String, amount: Money, proof: StepUpProof) -> APIRequest<ReleaseFromGoalResult> {
            .post("/goals/\(goalID.pathSegment)/release", body: ReleaseFromGoalInput(amount: amount, proof: proof))
        }

        /// `POST /goals/{id}/delete` (step-up; moves any savings back). Money move.
        public static func delete(goalID: String, proof: StepUpProof) -> APIRequest<DeleteGoalResult> {
            .post("/goals/\(goalID.pathSegment)/delete", body: proof)
        }
    }

    /// "Circles" in the API, "groups" in the UI.
    public enum Groups {
        /// `GET /circles`
        public static func list() -> APIRequest<[CircleSummary]> {
            .get("/circles")
        }

        /// `GET /circles/invites`
        public static func invites() -> APIRequest<[CircleInvite]> {
            .get("/circles/invites")
        }

        /// `GET /circles/{id}`
        public static func get(_ id: String) -> APIRequest<CircleDetail> {
            .get("/circles/\(id.pathSegment)")
        }

        /// `POST /circles`
        public static func create(_ input: CircleInput) -> APIRequest<CircleSummary> {
            .post("/circles", body: input)
        }

        /// `POST /circles/{id}/invite`
        public static func invite(groupID: String, email: String) -> APIRequest<OkResponse> {
            .post("/circles/\(groupID.pathSegment)/invite", body: InviteInput(email: email))
        }

        /// `POST /circles/{id}/start`
        public static func start(groupID: String) -> APIRequest<OkResponse> {
            .post("/circles/\(groupID.pathSegment)/start")
        }

        /// `POST /circles/{id}/delete`
        public static func delete(groupID: String) -> APIRequest<OkResponse> {
            .post("/circles/\(groupID.pathSegment)/delete")
        }

        /// `POST /circles/{id}/contribute` with `{}`: Pay in. Money move.
        public static func contribute(groupID: String) -> APIRequest<OkResponse> {
            .post("/circles/\(groupID.pathSegment)/contribute")
        }

        /// `POST /circles/invites/{id}/accept`
        public static func acceptInvite(_ inviteID: String) -> APIRequest<OkResponse> {
            .post("/circles/invites/\(inviteID.pathSegment)/accept")
        }

        /// `POST /circles/invites/{id}/decline`
        public static func declineInvite(_ inviteID: String) -> APIRequest<OkResponse> {
            .post("/circles/invites/\(inviteID.pathSegment)/decline")
        }
    }

    public enum Activity {
        /// `GET /activity?limit=` (server default 20).
        public static func list(limit: Int = 100) -> APIRequest<[ActivityItem]> {
            .get("/activity", query: [URLQueryItem(name: "limit", value: String(limit))])
        }
    }

    public enum Notifications {
        /// `GET /notifications`
        public static func list() -> APIRequest<NotificationsResponse> {
            .get("/notifications")
        }

        /// `GET /notifications/preferences`
        public static func preferences() -> APIRequest<NotificationPreferences> {
            .get("/notifications/preferences")
        }

        /// `PATCH /notifications/preferences`
        public static func updatePreferences(_ update: NotificationPreferencesUpdate) -> APIRequest<NotificationPreferences> {
            .patch("/notifications/preferences", body: update)
        }

        /// `POST /notifications/read-all`
        public static func markAllRead() -> APIRequest<OkResponse> {
            .post("/notifications/read-all")
        }

        /// `POST /notifications/{id}/read`
        public static func markRead(_ id: String) -> APIRequest<OkResponse> {
            .post("/notifications/\(id.pathSegment)/read")
        }
    }

    public enum Profile {
        /// `GET /profile`
        public static func get() -> APIRequest<UserProfile> {
            .get("/profile")
        }

        /// `PATCH /profile`
        public static func update(_ update: ProfileUpdate) -> APIRequest<UserProfile> {
            .patch("/profile", body: update)
        }
    }

    public enum Learn {
        /// `GET /learn/lessons`
        public static func lessons() -> APIRequest<[LessonSummary]> {
            .get("/learn/lessons")
        }

        /// `GET /learn/lessons/{slug}`
        public static func lesson(_ slug: String) -> APIRequest<LessonDetail> {
            .get("/learn/lessons/\(slug.pathSegment)")
        }

        /// `POST /learn/lessons/{slug}/complete` with `{}`: Mark as done. A
        /// repeat call answers 200 again; there is no undo.
        public static func complete(_ slug: String) -> APIRequest<OkResponse> {
            .post("/learn/lessons/\(slug.pathSegment)/complete")
        }
    }

    /// The account's savings streak. Every call answers the whole overview.
    /// Bodies come only from typed inputs, because a malformed body is a 500;
    /// the writes are never retried.
    public enum Streaks {
        /// `GET /streaks`
        public static func overview() -> APIRequest<StreakOverview> {
            .get("/streaks")
        }

        /// `POST /streaks/frequency` with `{"frequency":"daily"}`. Once a
        /// calendar year.
        public static func setFrequency(_ frequency: StreakFrequency) -> APIRequest<StreakOverview> {
            .post("/streaks/frequency", body: StreakFrequencyInput(frequency))
        }

        /// `POST /streaks/vacation` with `{"days":14}`: Take a break, once a
        /// calendar year.
        public static func startBreak(days: StreakBreakDays) -> APIRequest<StreakOverview> {
            .post("/streaks/vacation", body: StreakBreakInput(days))
        }

        /// `POST /streaks/vacation/end` with `{}`: End break early.
        public static func endBreak() -> APIRequest<StreakOverview> {
            .post("/streaks/vacation/end")
        }
    }

    /// Closing the account. Both send a JSON body (the routes refuse any other
    /// content type) and are never retried.
    public enum Account {
        /// `POST /account/deactivate` with the step-up proof. The server ends
        /// every session; signing in again turns the account back on.
        public static func deactivate(_ proof: StepUpProof) -> APIRequest<OkResponse> {
            .post("/account/deactivate", body: proof)
        }

        /// `DELETE /account` with `{"confirm":"DELETE", …}` and the step-up
        /// proof. Refused (409) while money, a forming or active group, or a
        /// goal remains.
        public static func delete(_ input: DeleteAccountInput) -> APIRequest<OkResponse> {
            .delete("/account", body: input)
        }
    }
}

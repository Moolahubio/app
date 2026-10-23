ALTER TABLE "ledger_accounts" DROP CONSTRAINT "ledger_accounts_user_id_users_id_fk";
--> statement-breakpoint
ALTER TABLE "ledger_accounts" DROP CONSTRAINT "ledger_accounts_goal_id_goals_id_fk";
--> statement-breakpoint
ALTER TABLE "ledger_accounts" DROP CONSTRAINT "ledger_accounts_circle_id_circles_id_fk";
--> statement-breakpoint
ALTER TABLE "postings" DROP CONSTRAINT "postings_transaction_id_transactions_id_fk";
--> statement-breakpoint
ALTER TABLE "postings" DROP CONSTRAINT "postings_account_id_ledger_accounts_id_fk";
--> statement-breakpoint
ALTER TABLE "ledger_accounts" ADD CONSTRAINT "ledger_accounts_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ledger_accounts" ADD CONSTRAINT "ledger_accounts_goal_id_goals_id_fk" FOREIGN KEY ("goal_id") REFERENCES "public"."goals"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "ledger_accounts" ADD CONSTRAINT "ledger_accounts_circle_id_circles_id_fk" FOREIGN KEY ("circle_id") REFERENCES "public"."circles"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "postings" ADD CONSTRAINT "postings_transaction_id_transactions_id_fk" FOREIGN KEY ("transaction_id") REFERENCES "public"."transactions"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "postings" ADD CONSTRAINT "postings_account_id_ledger_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."ledger_accounts"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "sessions_user_id_idx" ON "sessions" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "email_verification_codes_user_id_idx" ON "email_verification_codes" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "password_reset_codes_user_id_idx" ON "password_reset_codes" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "passkeys_user_id_idx" ON "passkeys" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "webauthn_challenges_user_id_idx" ON "webauthn_challenges" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "reauth_codes_user_id_idx" ON "reauth_codes" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "goals_user_id_idx" ON "goals" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "circle_invites_invited_by_id_idx" ON "circle_invites" USING btree ("invited_by_id");--> statement-breakpoint
CREATE INDEX "circle_members_user_id_idx" ON "circle_members" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "circles_created_by_id_idx" ON "circles" USING btree ("created_by_id");--> statement-breakpoint
CREATE INDEX "contributions_user_id_idx" ON "contributions" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "ledger_accounts_user_id_idx" ON "ledger_accounts" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "ledger_accounts_goal_id_idx" ON "ledger_accounts" USING btree ("goal_id");--> statement-breakpoint
CREATE INDEX "ledger_accounts_circle_id_idx" ON "ledger_accounts" USING btree ("circle_id");--> statement-breakpoint
CREATE INDEX "postings_transaction_id_idx" ON "postings" USING btree ("transaction_id");--> statement-breakpoint
CREATE INDEX "postings_account_id_idx" ON "postings" USING btree ("account_id");--> statement-breakpoint
CREATE INDEX "transactions_user_id_idx" ON "transactions" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "transactions_circle_id_idx" ON "transactions" USING btree ("circle_id");--> statement-breakpoint
CREATE INDEX "notifications_user_id_idx" ON "notifications" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "lesson_progress_user_id_idx" ON "lesson_progress" USING btree ("user_id");--> statement-breakpoint
CREATE INDEX "onchain_transfers_transaction_id_idx" ON "onchain_transfers" USING btree ("transaction_id");--> statement-breakpoint
CREATE INDEX "onchain_transfers_contribution_id_idx" ON "onchain_transfers" USING btree ("contribution_id");--> statement-breakpoint
CREATE INDEX "onchain_transfers_source_user_id_idx" ON "onchain_transfers" USING btree ("source_user_id");--> statement-breakpoint
CREATE INDEX "referral_earnings_referee_idx" ON "referral_earnings" USING btree ("referee_id");--> statement-breakpoint
CREATE INDEX "referral_withdrawals_transaction_idx" ON "referral_withdrawals" USING btree ("transaction_id");--> statement-breakpoint
-- Postings are append-only history: a mistake is corrected with a reversal
-- transaction, never by editing or removing rows. The FKs above RESTRICT so no
-- cascade can delete them either.
--
-- One narrow exception, for e2e teardown (lib/db/src/testing.ts): the table
-- OWNER may DELETE inside a transaction that sets moolahub.ledger_purge = 'on'.
-- The owner can drop this trigger anyway, so this grants it nothing new, and
-- the app role has no DELETE privilege on postings at all (revoked below).
-- UPDATE and TRUNCATE are always rejected.
CREATE OR REPLACE FUNCTION public.postings_append_only() RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE'
     AND current_setting('moolahub.ledger_purge', true) = 'on'
     AND pg_catalog.pg_has_role(
       current_user,
       (SELECT c.relowner FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID),
       'MEMBER'
     ) THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'postings are append-only: % is not allowed, post a reversal instead', TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;
--> statement-breakpoint
REVOKE ALL ON FUNCTION public.postings_append_only() FROM PUBLIC;
--> statement-breakpoint
CREATE TRIGGER postings_append_only
  BEFORE UPDATE OR DELETE ON public.postings
  FOR EACH ROW EXECUTE FUNCTION public.postings_append_only();
--> statement-breakpoint
CREATE TRIGGER postings_no_truncate
  BEFORE TRUNCATE ON public.postings
  FOR EACH STATEMENT EXECUTE FUNCTION public.postings_append_only();
--> statement-breakpoint
REVOKE UPDATE, DELETE, TRUNCATE ON public.postings FROM moolahub_app;

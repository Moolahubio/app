-- Least-privilege role for the API (spec §7). The table owner (`postgres` on
-- Supabase) keeps DDL and runs migrations; `moolahub_app` gets DML only, behind
-- RLS, with server-side timeouts. Safe on plain Postgres: the Supabase-specific
-- parts only run where those roles exist.
--
-- The role is created NOLOGIN with no password so no credential ever lands in
-- git. Out of band, once per environment, an owner runs (Supabase SQL editor or
-- psql as postgres; the password comes from the secret store, never a file):
--   ALTER ROLE moolahub_app WITH LOGIN PASSWORD '<generated, 32+ random chars>';
-- The API then connects through the transaction pooler (:6543) as
-- `moolahub_app.<project-ref>`. Also turn the Data API off in the dashboard:
-- the app never uses PostgREST.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'moolahub_app') THEN
    CREATE ROLE moolahub_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
  END IF;
END $$;
--> statement-breakpoint
-- No role but the owner creates objects in public (already the PG15+ default;
-- a warning, not an error, where the migrating role doesn't own the schema).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
--> statement-breakpoint
GRANT USAGE ON SCHEMA public TO moolahub_app;
--> statement-breakpoint
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO moolahub_app;
--> statement-breakpoint
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO moolahub_app;
--> statement-breakpoint
-- Tables created by later migrations get the same grants. Default privileges
-- belong to the role that creates the objects: `postgres` on Supabase, and the
-- migrating role itself on a local database.
DO $$
DECLARE owner_role text;
BEGIN
  FOR owner_role IN SELECT DISTINCT r FROM unnest(ARRAY[current_user::text, 'postgres']) AS r LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = owner_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO moolahub_app', owner_role);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO moolahub_app', owner_role);
  END LOOP;
END $$;
--> statement-breakpoint
-- RLS on every table, with one permissive policy for the app role. The owner
-- bypasses RLS; every other role (anon, authenticated, a leaked key) matches no
-- policy and sees nothing. A migration that adds a table must add `app_rw` too;
-- lib/db/ci/assert-db.sql fails CI if one is missing.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
    EXECUTE format('DROP POLICY IF EXISTS app_rw ON public.%I', t.tablename);
    EXECUTE format('CREATE POLICY app_rw ON public.%I FOR ALL TO moolahub_app USING (true) WITH CHECK (true)', t.tablename);
  END LOOP;
END $$;
--> statement-breakpoint
-- Role-level timeouts: the transaction pooler can't carry session SETs, so these
-- are the only timeouts that reliably apply to every API connection.
ALTER ROLE moolahub_app SET statement_timeout = '15s';
--> statement-breakpoint
ALTER ROLE moolahub_app SET lock_timeout = '5s';
--> statement-breakpoint
ALTER ROLE moolahub_app SET idle_in_transaction_session_timeout = '30s';
--> statement-breakpoint
-- Supabase's API roles get nothing in public, now or for future objects. 0001
-- covered anon and authenticated for the migrating role; this adds service_role
-- and pins the default privileges of `postgres` explicitly.
DO $$
DECLARE api_role text; owner_role text;
BEGIN
  FOREACH api_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = api_role);
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', api_role);
    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', api_role);
    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM %I', api_role);
    FOR owner_role IN SELECT DISTINCT r FROM unnest(ARRAY[current_user::text, 'postgres']) AS r LOOP
      CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = owner_role);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON TABLES FROM %I', owner_role, api_role);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON SEQUENCES FROM %I', owner_role, api_role);
      EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM %I', owner_role, api_role);
    END LOOP;
  END LOOP;
END $$;

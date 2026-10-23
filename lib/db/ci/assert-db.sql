-- Database security and integrity assertions (spec §7). Run as the table owner
-- after `drizzle-kit migrate`:
--   pnpm --filter @workspace/db run assert
-- CI runs it against `supabase start`; the runbook runs it against staging and
-- prod through the session pooler (for TLS there, set PGSSLMODE=verify-full and
-- PGSSLROOTCERT to the Supabase CA file; never put sslmode in the URL).
-- Every check raises on failure, so psql -v ON_ERROR_STOP=1 exits non-zero.
-- It writes nothing: the behavioural checks roll themselves back.

-- 1. RLS on, and the app_rw policy present, on every public table.
DO $$
DECLARE missing text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO missing
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity;
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'RLS disabled on: %', missing; END IF;

  SELECT string_agg(t.tablename, ', ') INTO missing
    FROM pg_tables t
   WHERE t.schemaname = 'public'
     AND NOT EXISTS (
       SELECT 1 FROM pg_policies p
        WHERE p.schemaname = 'public' AND p.tablename = t.tablename
          AND p.policyname = 'app_rw' AND 'moolahub_app' = ANY (p.roles)
     );
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'app_rw policy missing on: %', missing; END IF;
END $$;

-- 2. The app role: least privilege, server-side timeouts.
DO $$
DECLARE r pg_roles%ROWTYPE; settings text[]; s text; missing text;
BEGIN
  SELECT * INTO r FROM pg_roles WHERE rolname = 'moolahub_app';
  IF NOT FOUND THEN RAISE EXCEPTION 'role moolahub_app does not exist'; END IF;
  IF r.rolsuper OR r.rolcreaterole OR r.rolcreatedb OR r.rolbypassrls OR r.rolreplication THEN
    RAISE EXCEPTION 'moolahub_app has an elevated role attribute';
  END IF;
  IF has_schema_privilege('moolahub_app', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'moolahub_app can CREATE in schema public';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relowner = r.oid) THEN
    RAISE EXCEPTION 'moolahub_app owns objects in public';
  END IF;

  SELECT d.setconfig INTO settings FROM pg_db_role_setting d
   WHERE d.setrole = r.oid AND d.setdatabase = 0;
  FOREACH s IN ARRAY ARRAY['statement_timeout=15s', 'lock_timeout=5s', 'idle_in_transaction_session_timeout=30s'] LOOP
    IF settings IS NULL OR NOT s = ANY (settings) THEN
      RAISE EXCEPTION 'moolahub_app is missing role setting %', s;
    END IF;
  END LOOP;

  -- has_table_privilege with a list is true if ANY is held, so check each one.
  SELECT string_agg(format('%s %s', p.priv, t.tablename), ', ') INTO missing
    FROM pg_tables t CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) AS p(priv)
   WHERE t.schemaname = 'public' AND t.tablename <> 'postings'
     AND NOT has_table_privilege('moolahub_app', format('public.%I', t.tablename), p.priv);
  IF missing IS NOT NULL THEN RAISE EXCEPTION 'moolahub_app lacks: %', missing; END IF;

  IF NOT has_table_privilege('moolahub_app', 'public.postings', 'SELECT')
     OR NOT has_table_privilege('moolahub_app', 'public.postings', 'INSERT') THEN
    RAISE EXCEPTION 'moolahub_app cannot read or append postings';
  END IF;
  IF has_table_privilege('moolahub_app', 'public.postings', 'UPDATE, DELETE, TRUNCATE') THEN
    RAISE EXCEPTION 'moolahub_app can UPDATE, DELETE or TRUNCATE postings';
  END IF;
END $$;

-- 3. Supabase's API roles get nothing in public, now or by default.
DO $$
DECLARE api_role text; leaked text;
BEGIN
  FOREACH api_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = api_role);
    SELECT string_agg(c.relname, ', ') INTO leaked
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
       AND (has_table_privilege(api_role, c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
            OR (c.relkind = 'S' AND has_sequence_privilege(api_role, c.oid, 'USAGE, SELECT, UPDATE')));
    IF leaked IS NOT NULL THEN RAISE EXCEPTION '% has privileges on: %', api_role, leaked; END IF;

    -- Only the roles that create our objects matter (`postgres`, or the local
    -- migrating role); Supabase's own supabase_admin defaults never apply to them.
    IF EXISTS (
      SELECT 1 FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace,
             aclexplode(d.defaclacl) a
       WHERE n.nspname = 'public'
         AND d.defaclrole IN (SELECT oid FROM pg_roles WHERE rolname IN (current_user, 'postgres'))
         AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = api_role)
    ) THEN
      RAISE EXCEPTION '% still has default privileges in public', api_role;
    END IF;
  END LOOP;
END $$;

-- 4. Ledger integrity: RESTRICT FKs, append-only triggers, covering indexes.
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(conname, ', ') INTO bad
    FROM pg_constraint
   WHERE contype = 'f' AND conrelid IN ('public.postings'::regclass, 'public.ledger_accounts'::regclass)
     AND confdeltype <> 'r';
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'ledger FKs must be ON DELETE RESTRICT: %', bad; END IF;

  -- tgtype bits: 2 = BEFORE, 8 = DELETE, 16 = UPDATE, 32 = TRUNCATE.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.postings'::regclass AND tgenabled <> 'D'
                   AND tgtype & 2 = 2 AND tgtype & 8 = 8 AND tgtype & 16 = 16) THEN
    RAISE EXCEPTION 'postings has no enabled BEFORE UPDATE OR DELETE trigger';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.postings'::regclass AND tgenabled <> 'D'
                   AND tgtype & 2 = 2 AND tgtype & 32 = 32) THEN
    RAISE EXCEPTION 'postings has no enabled BEFORE TRUNCATE trigger';
  END IF;

  SELECT string_agg(format('%s(%s)', c.conrelid::regclass, c.conname), ', ') INTO bad
    FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
   WHERE c.contype = 'f' AND n.nspname = 'public'
     AND NOT EXISTS (
       SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.conrelid
          AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
          AND (i.indkey::int2[])[0:cardinality(c.conkey) - 1] <@ c.conkey
     );
  IF bad IS NOT NULL THEN RAISE EXCEPTION 'foreign keys without a covering index: %', bad; END IF;
END $$;

-- 5. Behaviour, not just catalog: as the owner, history still can't be edited.
DO $$
DECLARE acct uuid; txn uuid;
BEGIN
  BEGIN
    INSERT INTO public.ledger_accounts (key, kind, label)
      VALUES ('ci:assert:' || gen_random_uuid(), 'ci', 'CI assertion') RETURNING id INTO acct;
    INSERT INTO public.transactions (type, description) VALUES ('ci', 'CI assertion') RETURNING id INTO txn;
    INSERT INTO public.postings (transaction_id, account_id, amount_cents) VALUES (txn, acct, 0);

    BEGIN
      UPDATE public.postings SET amount_cents = 1 WHERE transaction_id = txn;
      RAISE EXCEPTION USING ERRCODE = 'MH002', MESSAGE = 'UPDATE on postings was allowed';
    EXCEPTION WHEN restrict_violation THEN NULL;
    END;
    BEGIN
      DELETE FROM public.postings WHERE transaction_id = txn;
      RAISE EXCEPTION USING ERRCODE = 'MH002', MESSAGE = 'DELETE on postings was allowed';
    EXCEPTION WHEN restrict_violation THEN NULL;
    END;
    BEGIN
      DELETE FROM public.transactions WHERE id = txn;
      RAISE EXCEPTION USING ERRCODE = 'MH002', MESSAGE = 'deleting a transaction with postings was allowed';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
      DELETE FROM public.ledger_accounts WHERE id = acct;
      RAISE EXCEPTION USING ERRCODE = 'MH002', MESSAGE = 'deleting a ledger account with postings was allowed';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;

    -- Roll back the probe rows.
    RAISE EXCEPTION USING ERRCODE = 'MH001';
  EXCEPTION WHEN SQLSTATE 'MH001' THEN NULL;
  END;
  RAISE NOTICE 'db assertions passed';
END $$;

-- =============================================================================
-- Melai Nuts — Migration 20261025020000: least-privilege grants (audit result)
-- =============================================================================
-- Run after 20261025010000_more_rate_limits.sql. Idempotent, one transaction.
--
-- AUDIT (2026-10-11, checked by supabase/tests/security_audit_test.sql on every CI run)
--   * anon (signed out): SELECT only, and only on the public catalog tables
--     (branches, branch_inventory, products, product_variants, product_categories,
--     promotions, rewards, payment_settings). No INSERT / UPDATE / DELETE anywhere.
--   * authenticated: SELECT on its own rows through RLS; writes only where the app
--     writes directly (customer_addresses, notification_preferences, notifications
--     delete / mark-read, staff_notifications delete, profile name/phone columns).
--     Everything else goes through SECURITY DEFINER functions that check the caller.
--   * Every public table has Row Level Security enabled.
--
-- CHANGES
--   1. pgcrypto's functions were executable by anon and authenticated because the
--      extension lives in the public schema on a plain Postgres. The app never calls
--      them directly (only SECURITY DEFINER functions do, as the owner), so EXECUTE is
--      revoked. gen_random_uuid / gen_random_bytes stay: column defaults use them.
--   2. Defence in depth: anon loses any INSERT / UPDATE / DELETE / TRUNCATE that a
--      future migration might add by mistake, on every existing table.
--   3. Internal helper functions (name starting with "_") are not executable by anon /
--      authenticated, except the CHECK-constraint helper _phone_chars_ok.
-- =============================================================================
begin;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.objid = p.oid and d.deptype = 'e'
      left join pg_extension e on e.oid = d.refobjid
     where n.nspname = 'public'
       and e.extname = 'pgcrypto'
       and p.proname not in ('gen_random_uuid', 'gen_random_bytes')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;

  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname like '\_%'
       and p.proname <> '_phone_chars_ok'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end;
$$;

revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- Tables created later are not exposed unless a migration grants them explicitly.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

commit;

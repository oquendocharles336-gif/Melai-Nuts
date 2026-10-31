-- =============================================================================
-- Melai Nuts — one-time repair: remove points wrongly credited at order placement
-- =============================================================================
-- Run once, by hand, after migration 20261031060000 and after the owner has
-- approved the corrections. Running it again changes nothing.
--
-- Every 'earn' row with no source came from the award-at-placement trigger and was
-- wrong: a completed order earned again through 'order_earn', a cancelled order
-- should earn nothing, and an open order earns when it completes.
--
-- The ledger is append-only, so each wrong row gets a correcting entry on its order.
-- A balance never goes below zero: a customer who already spent the extra points
-- keeps the discount, and the shortfall is forgiven.
-- =============================================================================
begin;

do $$
declare
  r record;
  v_take int;
  v_short int := 0;
begin
  for r in
    select t.firebase_uid, t.order_id, t.points
    from public.loyalty_transactions t
    where t.type = 'earn' and t.source is null and t.order_id is not null
      and not exists (select 1 from public.loyalty_transactions c
                      where c.order_id = t.order_id and c.source = 'admin_adjust'
                        and c.description like 'Correction:%')
    order by t.created_at, t.order_id
  loop
    select least(points_balance, r.points) into v_take
    from public.loyalty_accounts where firebase_uid = r.firebase_uid for update;

    v_short := v_short + r.points - coalesce(v_take, 0);
    continue when coalesce(v_take, 0) <= 0;

    update public.loyalty_accounts
    set points_balance = points_balance - v_take,
        lifetime_points = greatest(lifetime_points - r.points, 0)
    where firebase_uid = r.firebase_uid;

    insert into public.loyalty_transactions (firebase_uid, type, points, description, order_id, source)
    values (r.firebase_uid, 'redeem', -v_take,
            'Correction: points wrongly added when order ' || r.order_id || ' was placed',
            r.order_id, 'admin_adjust');
  end loop;

  if exists (
    select 1 from public.loyalty_accounts a
    where a.points_balance <> (select coalesce(sum(t.points), 0) from public.loyalty_transactions t
                               where t.firebase_uid = a.firebase_uid)
  ) then
    raise exception 'A balance no longer matches its ledger; nothing was changed.';
  end if;

  raise notice 'Points forgiven because they were already spent: %', v_short;
end $$;

commit;

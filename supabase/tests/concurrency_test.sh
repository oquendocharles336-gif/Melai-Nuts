#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — concurrency test for checkout, vouchers and loyalty points
# =============================================================================
# Races several REAL database sessions against each other to prove that
# simultaneous checkouts can never oversell stock, double-spend points, exceed a
# voucher limit, or create duplicate orders.
#
# To force genuine overlap (a fast function would otherwise finish before the
# next request starts), a "gate" session first holds a row lock, the racers all
# start and queue behind it, then the gate commits and they are released at once.
#
# USAGE (DEV / STAGING database only — it COMMITS data, then removes it):
#   DATABASE_URL="postgresql://postgres:<password>@<host>:5432/postgres" \
#     bash supabase/tests/concurrency_test.sh
#
# Needs: psql, and the schema + both migrations applied. Exits non-zero on any failure.
# The connecting role must be able to `SET ROLE authenticated` (the Supabase
# `postgres` role can). Cleanup uses session_replication_role=replica to bypass
# the append-only/immutability triggers for the test's own rows only.
# =============================================================================
set -u
: "${DATABASE_URL:?Set DATABASE_URL to a DEV/STAGING database}"

PSQL=(psql "$DATABASE_URL" -X -q -At -v ON_ERROR_STOP=0)
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'cleanup; rm -rf "$TMP"' EXIT

sql()  { "${PSQL[@]}" -c "$1" 2>&1; }
val()  { "${PSQL[@]}" -c "$1" 2>/dev/null | head -1; }

# Run SQL as an authenticated customer (own session, own transaction per call).
as_user() {
  local uid="$1"; shift
  "${PSQL[@]}" <<EOF 2>&1
select set_config('request.jwt.claims', '{"sub":"$uid","role":"authenticated","email":"$uid@conc.local","email_verified":true}', false) \g /dev/null
set role authenticated;
$*
EOF
}

assert() {  # assert "name" "actual" "expected"
  if [ "$2" == "$3" ]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL  %s   (expected [%s], got [%s])\n' "$1" "$3" "$2"; fi
}

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'EOF'
set session_replication_role = replica;
delete from public.notifications        where firebase_uid like 'conc\_%';
delete from public.voucher_usage        where firebase_uid like 'conc\_%';
delete from public.loyalty_transactions where firebase_uid like 'conc\_%';
delete from public.loyalty_accounts     where firebase_uid like 'conc\_%';
delete from public.payments             where firebase_uid like 'conc\_%';
delete from public.order_status_events  where order_id in (select id from public.orders where firebase_uid like 'conc\_%');
delete from public.order_items          where order_id in (select id from public.orders where firebase_uid like 'conc\_%');
delete from public.orders               where firebase_uid like 'conc\_%';
delete from public.cart_items           where cart_id in (select id from public.carts where firebase_uid like 'conc\_%');
delete from public.carts                where firebase_uid like 'conc\_%';
delete from public.customer_profiles    where firebase_uid like 'conc\_%';
delete from public.vouchers             where code like 'CONC%';
delete from public.branch_inventory     where branch_id in (select id from public.branches where name like 'CONC-%');
delete from public.product_variants     where product_id in (select id from public.products where name like 'CONC-%');
delete from public.products             where name like 'CONC-%';
delete from public.product_categories   where label like 'CONC-%';
delete from public.branches             where name like 'CONC-%';
EOF
}

# race <gate_sql> <cmd1> <cmd2> ... : hold the gate lock, start all racers (each
# writes its result to $TMP/r<i>), then release the gate so they run together.
race() {
  local gate="$1"; shift
  ( "${PSQL[@]}" <<EOF >/dev/null 2>&1
begin;
$gate
select pg_sleep(2.5);
commit;
EOF
  ) &
  local gate_pid=$!
  sleep 0.8
  local i=0 pids=()
  for cmd in "$@"; do
    i=$((i+1)); ( eval "$cmd" > "$TMP/r$i" 2>&1 ) & pids+=($!)
  done
  wait "${pids[@]}" "$gate_pid" 2>/dev/null
}

result_of() { grep -Eo 'ORD-[0-9]+' "$TMP/r$1" | head -1; }
errored()   { grep -q 'ERROR' "$TMP/r$1" && echo yes || echo no; }

echo "== setting up fixtures"
cleanup
"${PSQL[@]}" -q >/dev/null <<'EOF'
insert into public.branches (name, address, supports_delivery, supports_pickup) values ('CONC-1','x',true,true),('CONC-2','x',true,true);
insert into public.product_categories (label) values ('CONC-cat');
insert into public.products (category_id, name, price, unit) select id, 'CONC-Nut', 100, 'pack' from public.product_categories where label='CONC-cat';
insert into public.product_variants (product_id, label, price) select id, 'Regular', 100 from public.products where name='CONC-Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  select b.id, v.product_id, v.id, 1 from public.branches b, public.product_variants v
  where b.name like 'CONC-%' and v.product_id=(select id from public.products where name='CONC-Nut');
insert into public.customer_profiles (firebase_uid, full_name, email, phone)
  select 'conc_'||n, 'C'||n, 'conc_'||n||'@conc.local', '0917000000'||n from generate_series(1,4) n;
insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent) values ('default',1,50)
  on conflict (id) do update set points_per_peso=1, max_discount_percent=50;
EOF
B1=$(val "select id from public.branches where name='CONC-1'"); B2=$(val "select id from public.branches where name='CONC-2'")
PR=$(val "select id from public.products where name='CONC-Nut'"); VR=$(val "select id from public.product_variants where product_id='$PR'")

mkcart() {  # uid branch qty voucher redeem -> cart id
  as_user "$1" "select sync_customer_cart('$2'::uuid, jsonb_build_array(jsonb_build_object('product_id','$PR','variant_id','$VR','quantity',$3)), $4, $5)->>'cart_id';" | grep -Eo '[0-9a-f-]{36}' | head -1
}
place() {  # uid cart key
  as_user "$1" "select place_order('$2'::uuid,false,null,'Cash on Counter Pickup','','$3');"
}
stock() { val "select coalesce(sum(quantity),0) from public.branch_inventory where variant_id='$VR' and branch_id='$1'"; }

# ---------------------------------------------------------------------------
echo "== A. Two customers race for the LAST unit"
C1=$(mkcart conc_1 "$B1" 1 null false); C2=$(mkcart conc_2 "$B1" 1 null false)
race "select 1 from public.branch_inventory where branch_id='$B1' and variant_id='$VR' for update;" \
     "place conc_1 $C1 kA1" "place conc_2 $C2 kA2"
WON=0; [ -n "$(result_of 1)" ] && WON=$((WON+1)); [ -n "$(result_of 2)" ] && WON=$((WON+1))
assert "exactly one customer gets the last unit"        "$WON" "1"
assert "stock is 0, never negative (no overselling)"    "$(stock "$B1")" "0"
assert "exactly one order line for the item"            "$(val "select count(*) from public.order_items where product_name='CONC-Nut'")" "1"
assert "the loser got a clear 'left at this branch' error" "$(cat $TMP/r1 $TMP/r2 | grep -c 'left at this branch')" "1"

# ---------------------------------------------------------------------------
echo "== B. A double-tapped / retried checkout (same key) sent 4x at once"
"${PSQL[@]}" -q -c "update public.branch_inventory set quantity=5 where branch_id='$B2' and variant_id='$VR'" >/dev/null
C3=$(mkcart conc_3 "$B2" 2 null false)
race "select 1 from public.branch_inventory where branch_id='$B2' and variant_id='$VR' for update;" \
     "place conc_3 $C3 SAMEKEY" "place conc_3 $C3 SAMEKEY" "place conc_3 $C3 SAMEKEY" "place conc_3 $C3 SAMEKEY"
O1=$(result_of 1); O2=$(result_of 2); O3=$(result_of 3); O4=$(result_of 4)
assert "every retry returns the SAME order id (no confusing errors)" "$( [ -n "$O1" ] && [ "$O1" == "$O2" ] && [ "$O2" == "$O3" ] && [ "$O3" == "$O4" ] && echo same || echo different:$O1,$O2,$O3,$O4 )" "same"
assert "no request errored"                 "$(for i in 1 2 3 4; do errored $i; done | sort -u | tr '\n' ',')" "no,"
assert "exactly one order was created"      "$(val "select count(*) from public.orders where firebase_uid='conc_3'")" "1"
assert "stock deducted exactly once (5 -> 3)" "$(stock "$B2")" "3"
assert "exactly one payment"                "$(val "select count(*) from public.payments where firebase_uid='conc_3'")" "1"

# ---------------------------------------------------------------------------
echo "== C. Single-use voucher (limit 1) claimed by two customers at once"
"${PSQL[@]}" -q -c "insert into public.vouchers (code, discount_type, discount_value, usage_limit) values ('CONCV','percent',10,1)" >/dev/null
"${PSQL[@]}" -q -c "update public.branch_inventory set quantity=5 where branch_id='$B2' and variant_id='$VR'" >/dev/null
C4=$(mkcart conc_1 "$B2" 1 "'CONCV'" false); C5=$(mkcart conc_2 "$B2" 1 "'CONCV'" false)
race "select 1 from public.vouchers where code='CONCV' for update;" \
     "place conc_1 $C4 kC1" "place conc_2 $C5 kC2"
WON=0; [ -n "$(result_of 1)" ] && WON=$((WON+1)); [ -n "$(result_of 2)" ] && WON=$((WON+1))
assert "exactly one customer gets the voucher"      "$WON" "1"
assert "voucher used_count is exactly 1 (limit 1)"  "$(val "select used_count from public.vouchers where code='CONCV'")" "1"
assert "exactly one voucher_usage row"              "$(val "select count(*) from public.voucher_usage v join public.vouchers x on x.id=v.voucher_id where x.code='CONCV'")" "1"

# ---------------------------------------------------------------------------
echo "== D. Loyalty double-spend: 50 points used by two carts (two branches) at once"
"${PSQL[@]}" -q >/dev/null <<EOF
update public.branch_inventory set quantity=5 where variant_id='$VR';
insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values ('conc_4', 50, 50);
insert into public.loyalty_transactions (firebase_uid, type, points, description) values ('conc_4','earn',50,'seed');
EOF
D1=$(mkcart conc_4 "$B1" 1 null true); D2=$(mkcart conc_4 "$B2" 1 null true)
race "select 1 from public.loyalty_accounts where firebase_uid='conc_4' for update;" \
     "place conc_4 $D1 kD1" "place conc_4 $D2 kD2"
WON=0; [ -n "$(result_of 1)" ] && WON=$((WON+1)); [ -n "$(result_of 2)" ] && WON=$((WON+1))
assert "the 50 points fund exactly one order"       "$WON" "1"
assert "balance is 0, never negative"               "$(val "select points_balance from public.loyalty_accounts where firebase_uid='conc_4'")" "0"
assert "ledger debits exactly 50 in total"          "$(val "select coalesce(-sum(points),0) from public.loyalty_transactions where firebase_uid='conc_4' and source='order_redeem'")" "50"
assert "balance equals its ledger (no drift)"       "$(val "select count(*) from public.loyalty_ledger_drift where firebase_uid='conc_4'")" "0"

# ---------------------------------------------------------------------------
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

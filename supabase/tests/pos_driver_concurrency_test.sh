#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — races for the POS shift / void / return and driver functions
# (migrations 20261010000000 and 20261010010000)
# =============================================================================
# Fires N simultaneous sessions at the same action and checks it happened once:
#   1. N cashiers' devices open a shift at once           -> one open shift
#   2. N voids of one sale, DIFFERENT request keys          -> one void, stock back once, cash out once
#   3. N voids of one sale, the SAME request key (retries)  -> one void, every caller same answer, no errors
#   4. N "receive returned item" calls for 1 refunded unit  -> stock +1 once
#   5. N "delivered + cash collected" for one stop          -> payment confirmed once, order completed once
# Needs COMMITTED data, so it creates and then removes its own rows (prefix
# CC- / cc-). DEV / staging only.
#
#   DATABASE_URL=postgresql://... bash supabase/tests/pos_driver_concurrency_test.sh
# =============================================================================
set -uo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
N="${N:-8}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt)
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1  ($2)"; fail=1; }

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
set session_replication_role = replica;  -- skip append-only / FK triggers for OUR rows only
create temp table cc_orders as select id from public.orders where branch_id in (select id from public.branches where name like 'CC-%');
create temp table cc_refunds as select id from public.refund_requests where order_id in (select id from cc_orders);
create temp table cc_runs as select id from public.deliveries where branch_id in (select id from public.branches where name like 'CC-%');
delete from public.driver_locations where delivery_id in (select id from cc_runs);
delete from public.delivery_assignment_events where delivery_id in (select id from cc_runs);
delete from public.delivery_stops where delivery_id in (select id from cc_runs);
delete from public.deliveries where id in (select id from cc_runs);
delete from public.drivers where firebase_uid like 'cc-%';
delete from public.cash_drawer_events where session_id in (select id from public.cash_drawer_sessions where staff_uid like 'cc-%');
delete from public.pos_voids where order_id in (select id from cc_orders);
delete from public.refund_returned_items where refund_id in (select id from cc_refunds);
delete from public.refund_status_events where refund_request_id in (select id from cc_refunds);
delete from public.refund_items where refund_request_id in (select id from cc_refunds);
delete from public.refund_requests where id in (select id from cc_refunds);
delete from public.pos_sales where order_id in (select id from cc_orders);
delete from public.cash_drawer_sessions where staff_uid like 'cc-%';
delete from public.loyalty_transactions where order_id in (select id from cc_orders) or firebase_uid like 'cc-%';
delete from public.loyalty_accounts where firebase_uid like 'cc-%';
delete from public.notifications where firebase_uid like 'cc-%';
delete from public.voucher_usage where order_id in (select id from cc_orders);
delete from public.payments where order_id in (select id from cc_orders);
delete from public.order_status_events where order_id in (select id from cc_orders);
delete from public.order_items where order_id in (select id from cc_orders);
delete from public.orders where id in (select id from cc_orders);
delete from public.cart_items where cart_id in (select id from public.carts where firebase_uid like 'cc-%');
delete from public.carts where firebase_uid like 'cc-%';
delete from public.customer_addresses where firebase_uid like 'cc-%';
delete from public.customer_profiles where firebase_uid like 'cc-%';
delete from public.staff_request_keys where firebase_uid like 'cc-%';
delete from public.staff_audit_logs where staff_firebase_uid like 'cc-%';
delete from public.staff_notifications where recipient_uid like 'cc-%';
delete from public.staff_permission_grants where firebase_uid like 'cc-%';
delete from public.stock_movements where branch_id in (select id from public.branches where name like 'CC-%');
delete from public.inventory_batches where branch_id in (select id from public.branches where name like 'CC-%');
delete from public.branch_inventory where branch_id in (select id from public.branches where name like 'CC-%');
delete from public.staff_members where firebase_uid like 'cc-%';
delete from public.product_variants where product_id in (select id from public.products where name like 'CC-%');
delete from public.products where name like 'CC-%';
delete from public.product_categories where label like 'CC-%';
delete from public.branches where name like 'CC-%';
SQL
}
trap cleanup EXIT
cleanup

# --- fixtures (committed) -----------------------------------------------------
"${PSQL[@]}" >/dev/null <<'SQL'
insert into public.branches (name, address, delivery_fee) values ('CC-A', 'a', 0);
insert into public.product_categories (label) values ('CC-Cat');
insert into public.products (category_id, name, price, unit) select id, 'CC-Nut', 100, 'pack' from public.product_categories where label = 'CC-Cat';
insert into public.product_variants (product_id, label, price) select id, 'Regular', 100 from public.products where name = 'CC-Nut';
insert into public.branch_inventory (branch_id, product_id, variant_id, quantity)
  select b.id, v.product_id, v.id, 100 from public.branches b, public.product_variants v
  where b.name = 'CC-A' and v.product_id = (select id from public.products where name = 'CC-Nut');
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
  select 'cc-cash', 'CC Cashier', 'cc-cash@test.local', 'staff', id, 'active', true, true from public.branches where name = 'CC-A';
insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
  select 'cc-mgr', 'CC Manager', 'cc-mgr@test.local', 'staff', id, 'active', true, true from public.branches where name = 'CC-A';
insert into public.staff_permission_grants (firebase_uid, permission) values ('cc-mgr', 'void_pos_sales');
insert into public.customer_profiles (firebase_uid, full_name, email, phone) values ('cc-cust', 'CC Cust', 'cc-cust@test.local', '0917');
insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city) values ('cc-cust', 'CC', '0917', '1 St', 'Calamba');
insert into public.drivers (firebase_uid, full_name, branch_id) select 'cc-drv', 'CC Driver', id from public.branches where name = 'CC-A';
SQL
BA=$("${PSQL[@]}" -c "select id from public.branches where name='CC-A'")
VAR=$("${PSQL[@]}" -c "select v.id from public.product_variants v join public.products p on p.id=v.product_id where p.name='CC-Nut'")
PROD=$("${PSQL[@]}" -c "select id from public.products where name='CC-Nut'")
ADDR=$("${PSQL[@]}" -c "select id from public.customer_addresses where firebase_uid='cc-cust'")

as_user() { # uid, sql -> result or "ERROR: ..."
  local out
  out=$("${PSQL[@]}" -c "begin; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$1@test.local\",\"email_verified\":true}', true); set local role authenticated; $2; commit;" 2>&1)
  if grep -q 'ERROR' <<<"$out"; then grep -m1 'ERROR' <<<"$out"; else tail -1 <<<"$out"; fi
}
stock() { "${PSQL[@]}" -c "select quantity from public.branch_inventory where branch_id='$BA' and variant_id='$VAR'"; }
tmp=$(mktemp -d)

# --- 1. N simultaneous shift opens (different keys) -----------------------------
for i in $(seq 1 "$N"); do
  ( as_user cc-cash "select public.staff_open_shift('$BA', 1000, 'cc-open-key-$i') ->> 'session_id'" > "$tmp/open$i" ) &
done
wait
OPEN=$("${PSQL[@]}" -c "select count(*) from public.cash_drawer_sessions where staff_uid='cc-cash' and status='open'")
[ "$OPEN" -eq 1 ] && ok "$N simultaneous shift opens -> exactly one open shift" || bad "open shifts" "$OPEN"
SHIFT=$("${PSQL[@]}" -c "select id from public.cash_drawer_sessions where staff_uid='cc-cash' and status='open'")

# --- 2. N simultaneous voids, different keys ------------------------------------
SALE=$(as_user cc-cash "select public.staff_create_pos_sale('$BA', jsonb_build_array(jsonb_build_object('variant_id','$VAR','quantity',3)), 'cash', null, 300) ->> 'order_id'")
S0=$(stock)
for i in $(seq 1 "$N"); do
  ( as_user cc-mgr "select public.staff_void_pos_sale('$SALE', 'race void', 'cc-void-key-$i') ->> 'refund_id'" > "$tmp/v$i" ) &
done
wait
S1=$(stock)
VOIDS=$("${PSQL[@]}" -c "select count(*) from public.pos_voids where order_id='$SALE'")
CASH=$("${PSQL[@]}" -c "select count(*) from public.cash_drawer_events where session_id='$SHIFT' and event_type='cash_refund'")
REFUNDS=$("${PSQL[@]}" -c "select count(*) from public.refund_requests where order_id='$SALE'")
[ "$VOIDS" -eq 1 ] && [ "$REFUNDS" -eq 1 ] && ok "$N simultaneous voids -> one void, one refund" || bad "voids/refunds" "$VOIDS / $REFUNDS"
[ "$S1" -eq $((S0 + 3)) ] && ok "stock returned once (+3)" || bad "stock" "before $S0, after $S1"
[ "$CASH" -eq 1 ] && ok "cash taken out of the drawer once" || bad "cash refund events" "$CASH"

# --- 3. N simultaneous voids, SAME key (app retries) ----------------------------
SALE2=$(as_user cc-cash "select public.staff_create_pos_sale('$BA', jsonb_build_array(jsonb_build_object('variant_id','$VAR','quantity',2)), 'cash', null, 200) ->> 'order_id'")
for i in $(seq 1 "$N"); do
  ( as_user cc-mgr "select public.staff_void_pos_sale('$SALE2', 'retry void', 'cc-same-void-key-1') ->> 'refund_id'" > "$tmp/s$i" ) &
done
wait
SD=$(cat "$tmp"/s* | sort -u | wc -l | tr -d ' ')
SE=$(cat "$tmp"/s* | grep -c 'ERROR' || true)
SV=$("${PSQL[@]}" -c "select count(*) from public.pos_voids where order_id='$SALE2'")
[ "$SV" -eq 1 ] && ok "same-key voids -> one void" || bad "voids" "$SV"
[ "$SE" -eq 0 ] && ok "same-key voids -> no caller got an error" || bad "errors" "$(cat "$tmp"/s* | sort -u | tr '\n' ' ')"
[ "$SD" -eq 1 ] && ok "same-key voids -> every caller got the same refund id" || bad "distinct answers" "$SD"

# --- 4. N simultaneous receipts of 1 refunded unit ------------------------------
"${PSQL[@]}" >/dev/null -c "update public.cash_drawer_sessions set status = status where id = '$SHIFT'"
SALE3=$(as_user cc-cash "select public.staff_create_pos_sale('$BA', jsonb_build_array(jsonb_build_object('variant_id','$VAR','quantity',1)), 'cash', null, 100, 'cc-cust') ->> 'order_id'")
RF=$(as_user cc-cust "select public.request_refund('$SALE3', 'Damaged', '', jsonb_build_array(jsonb_build_object('product_name','CC-Nut','variant_label','Regular','quantity',1)))")
as_user cc-cash "select public.staff_review_refund('$RF', 'approve')" >/dev/null
R0=$(stock)
for i in $(seq 1 "$N"); do
  ( as_user cc-cash "select public.staff_receive_returned_items('$RF', jsonb_build_array(jsonb_build_object('variant_id','$VAR','quantity',1)), 'cc-recv-key-$i')::text" > "$tmp/r$i" ) &
done
wait
R1=$(stock)
RR=$("${PSQL[@]}" -c "select count(*) from public.refund_returned_items where refund_id='$RF'")
[ "$R1" -eq $((R0 + 1)) ] && [ "$RR" -eq 1 ] && ok "$N simultaneous receipts of 1 returned unit -> stock +1 once" || bad "returned stock" "before $R0, after $R1, rows $RR"

# --- 5. N simultaneous "delivered + cash collected" for one stop ----------------
CART=$(as_user cc-cust "select public.sync_customer_cart('$BA', jsonb_build_array(jsonb_build_object('product_id','$PROD','variant_id','$VAR','quantity',1)), null, false) ->> 'cart_id'")
ORD=$(as_user cc-cust "select public.place_order('$CART', true, '$ADDR', 'Cash on Delivery', '', 'cc-cod-order-1')")
as_user cc-mgr "select public.staff_update_order_status('$ORD', 'confirmed')" >/dev/null
RUN=$(as_user cc-mgr "select public.staff_create_delivery('$BA', 'Bike', 'TBD', array['$ORD']) ->> 'id'")
as_user cc-mgr  "select public.staff_assign_driver('$RUN', 'cc-drv')" >/dev/null
as_user cc-drv "select public.driver_respond_assignment('$RUN', 'accept')" >/dev/null
as_user cc-drv "select public.driver_mark_picked_up('$RUN')" >/dev/null
STOP=$("${PSQL[@]}" -c "select id from public.delivery_stops where delivery_id='$RUN'")
for i in $(seq 1 "$N"); do
  ( as_user cc-drv "select public.driver_update_stop('$STOP', 'delivered', null, null, null, 'CC Cust', 100) ->> 'status'" > "$tmp/d$i" ) &
done
wait
DE=$(cat "$tmp"/d* | grep -c 'ERROR' || true)
PAY=$("${PSQL[@]}" -c "select status from public.payments where order_id='$ORD'")
COD=$("${PSQL[@]}" -c "select count(*) from public.staff_audit_logs where action='payment.cod_collected' and entity_id='$ORD'")
DONE=$("${PSQL[@]}" -c "select count(*) from public.order_status_events where order_id='$ORD' and status='completed'")
RUNST=$("${PSQL[@]}" -c "select status from public.deliveries where id='$RUN'")
[ "$DE" -eq 0 ] && ok "$N simultaneous 'delivered' taps -> no caller got an error" || bad "errors" "$(cat "$tmp"/d* | sort -u | tr '\n' ' ')"
[ "$PAY" = "success" ] && [ "$COD" -eq 1 ] && ok "cash collection recorded once" || bad "payment/cod" "$PAY / $COD"
[ "$DONE" -eq 1 ] && [ "$RUNST" = "completed" ] && ok "order completed once, run completed" || bad "completed events / run" "$DONE / $RUNST"

rm -rf "$tmp"
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }

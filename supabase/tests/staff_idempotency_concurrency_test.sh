#!/usr/bin/env bash
# =============================================================================
# Melai Nuts — concurrent duplicate keyed staff requests apply exactly once
# =============================================================================
# Fires N simultaneous sessions that all send the SAME idempotency key (as a
# retrying app / offline queue replay would) and checks that the stock change
# or transfer happened once, every caller got the same answer, and nobody got
# an error. Needs COMMITTED data, so it creates and then removes its own
# fixtures. DEV / staging only.
#
#   DATABASE_URL=postgresql://... bash supabase/tests/staff_idempotency_concurrency_test.sh
# =============================================================================
set -uo pipefail
: "${DATABASE_URL:?set DATABASE_URL}"
N="${N:-8}"
PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt)
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1  ($2)"; fail=1; }

cleanup() {
  "${PSQL[@]}" >/dev/null 2>&1 <<'SQL'
delete from public.staff_request_keys where firebase_uid like 'idem-%';
delete from public.stock_transfer_batches where transfer_id in (select id from public.stock_transfers where requested_by like 'idem-%');
delete from public.stock_transfers where requested_by like 'idem-%';
delete from public.stock_movements where created_by like 'idem-%';
delete from public.inventory_batches where batch_code like 'IDEM-%';
delete from public.branch_inventory where branch_id in (select id from public.branches where name like 'IDEM-%');
delete from public.staff_members where firebase_uid like 'idem-%';
delete from public.products where name like 'IDEM-%';
delete from public.product_categories where label like 'IDEM-%';
delete from public.branches where name like 'IDEM-%';
SQL
}
trap cleanup EXIT
cleanup

# --- fixtures (committed) -----------------------------------------------------
"${PSQL[@]}" >/dev/null <<'SQL'
insert into public.branches (name, address, supports_delivery, supports_pickup, delivery_fee)
values ('IDEM-A','a',true,true,30), ('IDEM-B','b',true,true,30);
insert into public.product_categories (label) values ('IDEM-Cat');
insert into public.products (category_id, name, price, unit)
  select id,'IDEM-Nut',100,'pack' from public.product_categories where label='IDEM-Cat';
insert into public.product_variants (product_id,label,price)
  select id,'Reg',100 from public.products where name='IDEM-Nut';
insert into public.branch_inventory (branch_id,product_id,variant_id,quantity)
  select b.id, v.product_id, v.id, 50 from public.branches b, public.product_variants v
  where b.name like 'IDEM-%' and v.product_id=(select id from public.products where name='IDEM-Nut');
insert into public.staff_members (firebase_uid,full_name,email,role,branch_id,account_status,can_manage_inventory,can_review_refunds)
  select 'idem-a','Idem A','idem-a@test.local','staff',id,'active',true,false from public.branches where name='IDEM-A';
insert into public.staff_members (firebase_uid,full_name,email,role,branch_id,account_status,can_manage_inventory,can_review_refunds)
  select 'idem-b','Idem B','idem-b@test.local','staff',id,'active',true,false from public.branches where name='IDEM-B';
SQL

BA=$("${PSQL[@]}" -c "select id from public.branches where name='IDEM-A'")
BB=$("${PSQL[@]}" -c "select id from public.branches where name='IDEM-B'")
VAR=$("${PSQL[@]}" -c "select v.id from public.product_variants v join public.products p on p.id=v.product_id where p.name='IDEM-Nut'")

# A batch for branch B, via the real RPC as B's staff.
as_staff() { # uid, sql  -> prints the query result, or "ERROR: ..." if anything failed
  local out
  out=$("${PSQL[@]}" -c "begin; select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\",\"email\":\"$1@test.local\",\"email_verified\":true}', true); set local role authenticated; $2; commit;" 2>&1)
  if grep -q 'ERROR' <<<"$out"; then grep -m1 'ERROR' <<<"$out"; else tail -1 <<<"$out"; fi
}
as_staff idem-b "select public.staff_receive_batch('$BB','$VAR','IDEM-B1',10,current_date+60,null,null,true)" >/dev/null
BATCH=$("${PSQL[@]}" -c "select id from public.inventory_batches where batch_code='IDEM-B1'")
QTY0=$("${PSQL[@]}" -c "select quantity from public.inventory_batches where id='$BATCH'")

# --- 1. N simultaneous identical keyed adjustments ------------------------------
tmp=$(mktemp -d)
for i in $(seq 1 "$N"); do
  ( as_staff idem-b "select public.staff_adjust_batch('$BATCH', 5, 'Concurrency probe', null, 'idem-concurrent-adjust-1')::text" > "$tmp/adj$i" ) &
done
wait
QTY1=$("${PSQL[@]}" -c "select quantity from public.inventory_batches where id='$BATCH'")
MOVES=$("${PSQL[@]}" -c "select count(*) from public.stock_movements where reason='Concurrency probe'")
DISTINCT=$(cat "$tmp"/adj* | sort -u | wc -l | tr -d ' ')
ERRS=$(cat "$tmp"/adj* | grep -ci 'error' || true)
[ "$QTY1" -eq $((QTY0 + 5)) ] && ok "$N simultaneous identical adjustments changed stock once (+5)" || bad "stock after $N duplicates" "before $QTY0, after $QTY1"
[ "$MOVES" -eq 1 ]            && ok "exactly one stock movement recorded"                          || bad "movement rows" "$MOVES"
[ "$DISTINCT" -eq 1 ]         && ok "every caller received the same result"                        || bad "distinct results" "$DISTINCT: $(cat "$tmp"/adj* | sort -u | tr '\n' ' ')"
[ "$ERRS" -eq 0 ]             && ok "no caller got an error"                                       || bad "errors" "$ERRS"

# --- 2. N simultaneous identical keyed transfer requests ------------------------
for i in $(seq 1 "$N"); do
  ( as_staff idem-a "select public.staff_request_transfer('$BB','$BA','$VAR',2,'idem-xfer','idem-concurrent-xfer-01')" > "$tmp/xf$i" ) &
done
wait
ROWS=$("${PSQL[@]}" -c "select count(*) from public.stock_transfers where note='idem-xfer'")
XD=$(cat "$tmp"/xf* | sort -u | wc -l | tr -d ' ')
XE=$(cat "$tmp"/xf* | grep -ci 'error' || true)
[ "$ROWS" -eq 1 ] && ok "$N simultaneous identical transfer requests created one transfer" || bad "transfer rows" "$ROWS"
[ "$XD" -eq 1 ]   && ok "every caller received the same transfer id"                      || bad "distinct ids" "$XD"
[ "$XE" -eq 0 ]   && ok "no caller got an error"                                           || bad "errors" "$XE"

# --- 3. N simultaneous DIFFERENT keys are NOT collapsed -------------------------
for i in $(seq 1 "$N"); do
  ( as_staff idem-b "select public.staff_adjust_batch('$BATCH', 1, 'Distinct probe', null, 'idem-distinct-key-$i')::text" > "$tmp/d$i" ) &
done
wait
DM=$("${PSQL[@]}" -c "select count(*) from public.stock_movements where reason='Distinct probe'")
[ "$DM" -eq "$N" ] && ok "$N different keys were each applied (keys do not over-collapse)" || bad "distinct-key movements" "$DM of $N"

# --- 4. N simultaneous ships of the SAME transfer (no key: outcome-idempotent) ----
inv() { "${PSQL[@]}" -c "select quantity from public.branch_inventory where branch_id='$1' and variant_id='$VAR'"; }
TID=$("${PSQL[@]}" -c "select id from public.stock_transfers where note='idem-xfer'")
B0=$(inv "$BB"); A0=$(inv "$BA")
for i in $(seq 1 "$N"); do
  ( as_staff idem-b "select public.staff_respond_transfer('$TID','ship')" > "$tmp/sh$i" ) &
done
wait
B1=$(inv "$BB")
STATUS=$("${PSQL[@]}" -c "select status from public.stock_transfers where id='$TID'")
LINES=$("${PSQL[@]}" -c "select count(*) from public.stock_transfer_batches where transfer_id='$TID'")
OUTM=$("${PSQL[@]}" -c "select count(*) from public.stock_movements where movement_type='transfer_out' and reference='$TID'")
SE=$(cat "$tmp"/sh* | grep -c 'ERROR' || true)
[ "$SE" -eq 0 ]                  && ok "$N simultaneous ships: none got an error"                      || bad "ship errors" "$SE"
[ "$STATUS" = "in_transit" ]     && ok "transfer is in transit"                                        || bad "status" "$STATUS"
[ "$B1" -eq $((B0 - 2)) ]        && ok "source stock reduced once (-2), not $N times"                  || bad "source stock" "before $B0, after $B1"
[ "$LINES" -eq 1 ] && [ "$OUTM" -eq 1 ] && ok "one batch line and one outgoing movement"                || bad "lines/movements" "$LINES / $OUTM"

# --- 5. N simultaneous receives of the SAME transfer ------------------------------
for i in $(seq 1 "$N"); do
  ( as_staff idem-a "select public.staff_respond_transfer('$TID','receive')" > "$tmp/rc$i" ) &
done
wait
A1=$(inv "$BA")
STATUS=$("${PSQL[@]}" -c "select status from public.stock_transfers where id='$TID'")
INM=$("${PSQL[@]}" -c "select count(*) from public.stock_movements where movement_type='transfer_in' and reference='$TID'")
RE=$(cat "$tmp"/rc* | grep -c 'ERROR' || true)
[ "$RE" -eq 0 ]               && ok "$N simultaneous receives: none got an error"                      || bad "receive errors" "$RE"
[ "$STATUS" = "received" ]    && ok "transfer is received"                                             || bad "status" "$STATUS"
[ "$A1" -eq $((A0 + 2)) ]     && ok "destination stock increased once (+2), not $N times"              || bad "destination stock" "before $A0, after $A1"
[ "$INM" -eq 1 ]              && ok "one incoming movement"                                            || bad "incoming movements" "$INM"

# --- 6. N simultaneous identical keyed batch receipts -----------------------------
A2=$(inv "$BA")
for i in $(seq 1 "$N"); do
  ( as_staff idem-a "select public.staff_receive_batch('$BA','$VAR','IDEM-A-KEYED',7,current_date+60,null,null,false,'idem-concurrent-recv-001')::text" > "$tmp/rb$i" ) &
done
wait
A3=$(inv "$BA")
RB=$("${PSQL[@]}" -c "select count(*) from public.inventory_batches where batch_code='IDEM-A-KEYED'")
RD=$(cat "$tmp"/rb* | sort -u | wc -l | tr -d ' ')
RBE=$(cat "$tmp"/rb* | grep -c 'ERROR' || true)
[ "$RBE" -eq 0 ]            && ok "$N simultaneous identical receipts: none got an error"              || bad "receipt errors" "$RBE"
[ "$RB" -eq 1 ]             && ok "exactly one batch created"                                          || bad "batches" "$RB"
[ "$RD" -eq 1 ]             && ok "every caller received the same batch id"                            || bad "distinct ids" "$RD"
[ "$A3" -eq $((A2 + 7)) ]   && ok "stock increased once (+7), not $N times"                            || bad "stock" "before $A2, after $A3"

rm -rf "$tmp"
echo
[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }

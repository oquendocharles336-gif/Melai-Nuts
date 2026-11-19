# =============================================================================
# Melai Nuts — "online first, every order" for the concurrency scripts
# =============================================================================
# Since migration 20261119080000 every customer order with something to pay is paid
# online first (Online Payment 100%, Cash on Counter Pickup the owner's downpayment),
# there are no cash-only orders, and no orders are taken while online payment is off.
#
# Source it after the script's PSQL=(psql "$DATABASE_URL" ...) array is defined:
#
#   . "$(dirname "$0")/online_first_settings.sh"
#
#   online_first_on        remember the current settings, then switch online payment on and
#                          set the owner's live downpayment (50%, 30 minutes, 2 days)
#   online_first_restore   put the remembered settings back (call it from the EXIT trap)
#   pay_online <order_id>  HitPay confirms the order's online part, exactly as the webhook does
#
# Not a test itself: run-sql-tests.sh only runs *_test.sh files.
# =============================================================================

OF_RESTORE=""

online_first_on() {
  OF_RESTORE="$("${PSQL[@]}" -At -c "select
      format('update public.payment_settings set online_payment_enabled = %L where id = ''default'';',
             (select online_payment_enabled from public.payment_settings where id = 'default'))
      || case when b.id is null then 'delete from public.business_settings where id = ''default'';'
         else format('update public.business_settings set cod_downpayment_type = %L, cod_downpayment_value = %L,'
                     ' cod_downpayment_min_order = %L, cod_downpayment_expiry_minutes = %L, cod_downpayment_pickup_days = %L'
                     ' where id = ''default'';',
                     b.cod_downpayment_type, b.cod_downpayment_value, b.cod_downpayment_min_order,
                     b.cod_downpayment_expiry_minutes, b.cod_downpayment_pickup_days) end
    from (select 1) x left join public.business_settings b on b.id = 'default'")"
  "${PSQL[@]}" -q >/dev/null <<'EOF'
update public.payment_settings set online_payment_enabled = true where id = 'default';
insert into public.business_settings (id, cod_downpayment_type, cod_downpayment_value, cod_downpayment_min_order,
                                      cod_downpayment_expiry_minutes, cod_downpayment_pickup_days)
values ('default', 'percent', 50, null, 30, 2)
on conflict (id) do update set
  cod_downpayment_type = excluded.cod_downpayment_type,
  cod_downpayment_value = excluded.cod_downpayment_value,
  cod_downpayment_min_order = excluded.cod_downpayment_min_order,
  cod_downpayment_expiry_minutes = excluded.cod_downpayment_expiry_minutes,
  cod_downpayment_pickup_days = excluded.cod_downpayment_pickup_days;
EOF
}

online_first_restore() {
  [ -n "$OF_RESTORE" ] && "${PSQL[@]}" -q -c "$OF_RESTORE" >/dev/null 2>&1
  OF_RESTORE=""
}

pay_online() {
  "${PSQL[@]}" -At -c "select public.hitpay_set_checkout('$1', 'preq-of-$1', 'https://pay.example/of-$1');
                       select public.hitpay_apply_payment('$1', 'success', 'qrph', 'pay-of-$1', null, 'preq-of-$1');" 2>&1 | tail -1
}

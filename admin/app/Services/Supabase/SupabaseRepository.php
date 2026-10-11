<?php

namespace App\Services\Supabase;

use Carbon\CarbonInterface;

/**
 * One method per Supabase function the admin portal uses, always acting as the signed-in
 * user's linked staff account. Read functions are defined in
 * supabase/migrations/20261009000000_admin_portal.sql; actions reuse the app's own staff
 * functions (staff_confirm_payment, staff_set_product_active, ...).
 */
class SupabaseRepository
{
    private array $memo = [];

    public function __construct(private SupabaseGateway $gateway, private StaffIdentity $identity) {}

    private function call(string $sql, array $bindings = []): mixed
    {
        return $this->gateway->call($this->identity->uid(), $sql, $bindings);
    }

    private function memo(string $key, \Closure $load): mixed
    {
        return array_key_exists($key, $this->memo) ? $this->memo[$key] : ($this->memo[$key] = $load());
    }

    private function forget(): void
    {
        $this->memo = [];
        $this->prefetched = [];
    }

    /** Answers loaded by prefetch() for reads that are not memoised: each is used once. */
    private array $prefetched = [];

    private function take(string $key, \Closure $load): mixed
    {
        if (array_key_exists($key, $this->prefetched)) {
            $v = $this->prefetched[$key];
            unset($this->prefetched[$key]);

            return $v;
        }

        return $load();
    }

    /**
     * SPEED: several read functions in ONE round trip to Supabase:
     *     select json_build_object('p0', public.f(...), 'p1', public.g(...))::text
     * sent through call(), i.e. as the signed-in staff account with the same claims and role as
     * every single call, so RLS and the staff / owner checks inside each function apply unchanged.
     * The answers are handed to the normal methods (orders(), stock(), ...), which then return them
     * without another round trip.
     *
     * $reads: list of [method, args]. If the batch fails for ANY reason (a function missing on an
     * older database, a permission check, ...) nothing is prefetched and every method simply runs
     * its own call as before, with its usual error handling and fallbacks.
     */
    public function prefetch(array $reads): void
    {
        $parts = [];
        foreach ($reads as [$method, $args]) {
            [$key, $expr, $bindings, $memo] = $this->spec($method, $args);
            if (($memo && array_key_exists($key, $this->memo)) || array_key_exists($key, $this->prefetched) || isset($parts[$key])) {
                continue;
            }
            $parts[$key] = [$expr, $bindings, $memo];
        }
        if (count($parts) < 2) {
            return; // one read: no gain, the method makes its own call
        }
        $sql = [];
        $bind = [];
        $alias = [];
        foreach (array_values(array_keys($parts)) as $i => $key) {
            $sql[] = "'p$i', ".$parts[$key][0];
            array_push($bind, ...$parts[$key][1]);
            $alias["p$i"] = $key;
        }
        try {
            $r = $this->call('select json_build_object('.implode(', ', $sql).')::text as r', $bind) ?? [];
        } catch (\App\Exceptions\BackendActionException|\App\Exceptions\BackendUnavailableException) {
            return;
        }
        foreach ($alias as $a => $key) {
            $value = $r[$a] ?? [];
            if ($parts[$key][2]) {
                $this->memo[$key] = $value;
            } else {
                $this->prefetched[$key] = $value;
            }
        }
    }

    /** [memo key, SQL expression, bindings, memoised?] of a read, exactly as its method would call it. */
    private function spec(string $method, array $a): array
    {
        $ts = fn (CarbonInterface $d) => $d->format('Y-m-d\TH:i:s.uP');

        return match ($method) {
            'orders' => ['orders:'.$ts($a[0]).':'.$ts($a[1]).':'.($a[2] ?? null), 'public.admin_portal_orders(?::timestamptz, ?::timestamptz, ?::uuid)', [$ts($a[0]), $ts($a[1]), $a[2] ?? null], true],
            'stock' => ['stock', 'public.admin_portal_stock()', [], true],
            'loyaltySummary' => ['loyalty-summary', 'public.admin_portal_loyalty_summary()', [], true],
            'staffOverview' => ['staff-overview:'.$ts($a[0]).':'.$ts($a[1]).':'.($a[2] ?? null), 'public.owner_staff_overview(?::timestamptz, ?::timestamptz, ?::uuid)', [$ts($a[0]), $ts($a[1]), $a[2] ?? null], true],
            'analyticsReport' => ["report:{$a[0]}:{$a[1]}:".($a[2] ?? null), 'public.analytics_report(?::date, ?::date, ?::uuid)', [$a[0], $a[1], $a[2] ?? null], true],
            'businessSettings' => ['business-settings', 'public.get_business_settings()', [], true],
            'salesOverview' => ["sales:{$a[0]}:{$a[1]}:".($a[2] ?? null), 'public.sales_overview(?::date, ?::date, ?::uuid)', [$a[0], $a[1], $a[2] ?? null], true],
            'products' => ['products', 'public.admin_portal_products()', [], false],
            'inventory' => ['inventory:'.$a[0], 'public.staff_get_inventory(?::uuid)', [$a[0]], false],
            'stockMovements' => ['movements:'.($a[0] ?? null).':'.($a[1] ?? 100), 'public.admin_portal_stock_movements(?::uuid, ?::int)', [$a[0] ?? null, $a[1] ?? 100], false],
            'reorderSuggestions' => ['reorder:'.$a[0], 'public.staff_reorder_suggestions(?::uuid, ?::int, ?::int, ?::int, ?::int)', [$a[0], 28, 7, 3, 14], false],
            'expiringBatches' => ['expiring:'.$a[0].':'.($a[1] ?? 30), 'public.staff_expiring_batches(?::uuid, ?::int)', [$a[0], $a[1] ?? 30], false],
            'purchaseReceipts' => ['receipts:'.($a[0] ?? null).':'.($a[1] ?? null), 'public.staff_list_purchase_receipts(?::uuid, ?::text, 200)', [$a[0] ?? null, $a[1] ?? null], false],
        };
    }

    // ---- reads ------------------------------------------------------------------------

    public function orders(CarbonInterface $from, CarbonInterface $to, ?string $branchId = null): array
    {
        // Microsecond precision: a second-precision "to" would hide orders placed in the current second.
        [$f, $t] = [$from->format('Y-m-d\TH:i:s.uP'), $to->format('Y-m-d\TH:i:s.uP')];

        return $this->memo("orders:$f:$t:$branchId", fn () => $this->call(
            'select public.admin_portal_orders(?::timestamptz, ?::timestamptz, ?::uuid)::text as r',
            [$f, $t, $branchId],
        ) ?? []);
    }

    public function stock(): array
    {
        return $this->memo('stock', fn () => $this->call('select public.admin_portal_stock()::text as r') ?? []);
    }

    public function products(): array
    {
        return $this->take('products', fn () => $this->call('select public.admin_portal_products()::text as r') ?? []);
    }

    public function stockMovements(?string $branchId, int $limit = 100): array
    {
        return $this->take("movements:$branchId:$limit", fn () => $this->call('select public.admin_portal_stock_movements(?::uuid, ?::int)::text as r', [$branchId, $limit]) ?? []);
    }

    public function inventory(string $branchId): array
    {
        return $this->take("inventory:$branchId", fn () => $this->call('select public.staff_get_inventory(?::uuid)::text as r', [$branchId]) ?? []);
    }

    /** Owner only (raises otherwise). */
    public function salesSummary(int $days): array
    {
        return $this->call('select public.owner_sales_summary(?::int)::text as r', [$days]) ?? [];
    }

    public function loyaltySummary(): array
    {
        return $this->memo('loyalty-summary', fn () => $this->call('select public.admin_portal_loyalty_summary()::text as r') ?? []);
    }

    public function loyaltyMembers(?string $search, int $limit = 200): array
    {
        return $this->call('select public.admin_portal_loyalty_members(?::text, ?::int)::text as r', [$search, $limit]) ?? [];
    }

    public function loyaltyMember(string $firebaseUid): ?array
    {
        return $this->call('select public.admin_portal_loyalty_member(?::text)::text as r', [$firebaseUid]);
    }

    /**
     * Owner-editable business settings + branch details (migration 20261018000000). Every value
     * may be null = "Not set"; nothing is filled in here.
     */
    public function businessSettings(): array
    {
        return $this->memo('business-settings', fn () => $this->call('select public.get_business_settings()::text as r') ?? []);
    }

    /** $values: only the keys to change; null clears a value. Owner only (checked by the database). */
    public function updateBusinessSettings(array $values): array
    {
        $this->forget();

        return $this->call('select public.owner_update_business_settings(?::jsonb)::text as r', [json_encode((object) $values)]) ?? [];
    }

    /** Create ($id null) or update a branch's details. Returns the branch id. Owner only. */
    public function saveBranch(?string $id, array $d): string
    {
        $this->forget();
        $bool = fn ($v) => $v === null ? null : ($v ? 'true' : 'false');
        $r = $this->call('select public.owner_save_branch(?::uuid, ?::text, ?::text, ?::text, ?::text, ?::numeric, ?::numeric, ?::boolean, ?::boolean, ?::boolean)::text as r', [
            $id, $d['name'], $d['address'] ?? null, $d['contact_phone'] ?? null, $d['operating_hours'] ?? null,
            $d['delivery_fee'], $d['daily_sales_target'] ?? null,
            $bool($d['supports_delivery'] ?? null), $bool($d['supports_pickup'] ?? null), $bool($d['is_active'] ?? null),
        ]) ?? [];

        return (string) ($r['id'] ?? $id);
    }

    /** Marks a branch as a warehouse (stock only, no sales) or back as a shop. Owner only. */
    public function setBranchWarehouse(string $branchId, bool $isWarehouse): void
    {
        $this->forget();
        $this->call('select public.owner_set_branch_warehouse(?::uuid, ?::boolean)::text as r', [$branchId, $isWarehouse ? 'true' : 'false']);
    }

    public function loyaltySettings(): array
    {
        return $this->call('select public.admin_portal_loyalty_settings()::text as r') ?? [];
    }

    public function auditLogs(int $limit = 100, ?string $before = null): array
    {
        return $this->call('select public.admin_portal_audit_logs(?::int, ?::timestamptz)::text as r', [$limit, $before]) ?? [];
    }

    /** Owner only. */
    public function staffDirectory(): array
    {
        return $this->call('select public.admin_portal_staff_directory()::text as r') ?? [];
    }

    /**
     * Owner only (raises otherwise): every account in the app in one call, as
     * ['staff' => [...], 'customers' => [...], 'customers_total' => int, 'partial' => bool].
     * Delivery drivers are app-only accounts (managed in the app), so the 'drivers' list the database
     * function also returns is dropped here and never reaches the website.
     * Customers are newest first, filtered by $search and capped at $limit.
     * Migration 20261014000000_admin_portal_all_users.sql. On an older database the lists are
     * built from the existing functions instead and 'partial' is true: customers then only
     * include loyalty members, and their order figures are unknown (null, never shown as 0).
     */
    public function allUsers(?string $search = null, int $limit = 500): array
    {
        $search = ($s = trim((string) $search)) === '' ? null : $s;

        return $this->memo("all-users:$search:$limit", function () use ($search, $limit) {
            try {
                $all = ($this->call('select public.owner_all_users(?::text, ?::int)::text as r', [$search, $limit]) ?? []) + ['partial' => false];
                unset($all['drivers']);

                return $all;
            } catch (\App\Exceptions\BackendUnavailableException $e) {
                if (! SupabaseGateway::isMissingFunction($e)) {
                    throw $e;
                }
                $customers = array_map(fn ($m) => [
                    'firebase_uid' => $m['id'], 'full_name' => $m['name'], 'email' => $m['email'] ?? '', 'phone' => null,
                    'card_number' => $m['card_number'] ?? null, 'branch_id' => null, 'branch_name' => null, 'created_at' => null,
                    'orders' => null, 'paid_total' => null, 'last_order_at' => null, 'points_balance' => $m['balance'] ?? null,
                ], $this->loyaltyMembers($search, $limit));

                return ['staff' => $this->staffDirectory(), 'customers' => $customers,
                    'customers_total' => count($customers), 'partial' => true];
            }
        });
    }

    /**
     * Owner only (raises otherwise): every staff account with its activity in [from, to) across all
     * branches, or one branch: POS sales and refunds per cashier, shifts, open drawer, last activity.
     * Migration 20261013000000_admin_portal_owner_overview.sql.
     */
    public function staffOverview(CarbonInterface $from, CarbonInterface $to, ?string $branchId = null): array
    {
        [$f, $t] = [$from->format('Y-m-d\TH:i:s.uP'), $to->format('Y-m-d\TH:i:s.uP')];

        return $this->memo("staff-overview:$f:$t:$branchId", function () use ($f, $t, $branchId) {
            try {
                return $this->call('select public.owner_staff_overview(?::timestamptz, ?::timestamptz, ?::uuid)::text as r', [$f, $t, $branchId]) ?? [];
            } catch (\App\Exceptions\BackendUnavailableException $e) {
                if (! SupabaseGateway::isMissingFunction($e)) {
                    throw $e;
                }
                // Migration 20261013000000 not run yet: the staff list still comes from the existing
                // admin_portal_staff_directory(); activity is UNKNOWN (null), never shown as 0.
                $none = array_fill_keys(['pos_transactions', 'pos_sales', 'pos_refunds', 'pos_net_sales', 'shifts_opened', 'open_shift', 'last_activity_at'], null);

                return array_values(array_map(fn ($s) => $s + $none + ['activity_unavailable' => true],
                    array_filter($this->staffDirectory(), fn ($s) => $branchId === null || ($s['branch_id'] ?? null) === $branchId)));
            }
        });
    }

    // ---- sales figures (migration 20261015000000_refunds_in_analytics.sql) -------------------

    /**
     * THE sales figures every page shows (gross, discounts, refunds, net, refund rate, pending
     * refunds; by day / branch / payment method / channel / cashier / product), computed once by
     * public.sales_overview() with the same definition the app uses. Dates are Asia/Manila days.
     * Owner: all branches (null) or one; staff: their own branch whatever is asked.
     * Returns null when the function is not installed yet (migration not run): pages then show
     * "—", never 0 and never a figure computed here.
     */
    public function salesOverview(string $from, string $to, ?string $branchId = null): ?array
    {
        return $this->memo("sales:$from:$to:$branchId", function () use ($from, $to, $branchId) {
            try {
                return $this->call('select public.sales_overview(?::date, ?::date, ?::uuid)::text as r', [$from, $to, $branchId]) ?? null;
            } catch (\App\Exceptions\BackendUnavailableException $e) {
                if (SupabaseGateway::isMissingFunction($e)) {
                    return null;
                }
                throw $e;
            }
        }) ?: null;
    }

    // ---- analytics and cash drawer (migrations 20261010*) ---------------------------------

    /** Owner: all branches or one; staff with view_reports: own branch. Dates are Asia/Manila days. */
    public function analyticsReport(string $from, string $to, ?string $branchId): array
    {
        return $this->memo("report:$from:$to:$branchId", fn () => $this->call(
            'select public.analytics_report(?::date, ?::date, ?::uuid)::text as r', [$from, $to, $branchId]) ?? []);
    }

    public function salesForecast(string $branchId, ?string $variantId, string $metric, string $granularity,
        ?string $trainFrom, ?string $trainTo, int $horizon, ?int $holdout, bool $save = false): array
    {
        return $this->call(
            'select public.analytics_sales_forecast(?::uuid, ?::uuid, ?::text, ?::text, ?::date, ?::date, ?::int, ?::int, ?::boolean)::text as r',
            [$branchId, $variantId, $metric, $granularity, $trainFrom, $trainTo, $horizon, $holdout, $save ? 'true' : 'false']) ?? [];
    }

    public function forecastAccuracy(string $runId): array
    {
        return $this->call('select public.analytics_forecast_accuracy(?::uuid)::text as r', [$runId]) ?? [];
    }

    public function reorderSuggestions(string $branchId, int $lookback = 28, int $leadTime = 7, int $safety = 3, int $cover = 14): array
    {
        $load = fn () => $this->call('select public.staff_reorder_suggestions(?::uuid, ?::int, ?::int, ?::int, ?::int)::text as r',
            [$branchId, $lookback, $leadTime, $safety, $cover]) ?? [];

        // prefetch() only knows the default parameters
        return [$lookback, $leadTime, $safety, $cover] === [28, 7, 3, 14] ? $this->take("reorder:$branchId", $load) : $load();
    }

    public function expiringBatches(string $branchId, int $withinDays = 30): array
    {
        return $this->take("expiring:$branchId:$withinDays", fn () => $this->call('select public.staff_expiring_batches(?::uuid, ?::int)::text as r', [$branchId, $withinDays]) ?? []);
    }

    public function shifts(?string $branchId, string $from, string $to): array
    {
        return $this->call('select public.staff_list_shifts(?::uuid, ?::date, ?::date)::text as r', [$branchId, $from, $to]) ?? [];
    }

    public function cashierDailySummary(string $branchId, string $date): array
    {
        return $this->call('select public.staff_cashier_daily_summary(?::uuid, ?::date)::text as r', [$branchId, $date]) ?? [];
    }

    // ---- actions (each one transaction; the SQL functions lock rows and check permissions) ----

    /** Confirms a pending payment (cash needs no reference; other methods need one). */
    public function confirmPayment(string $orderId, ?string $reference = null): void
    {
        $this->call('select public.staff_confirm_payment(?::text, ?::text)::text as r', [$orderId, $reference]);
        $this->forget();
    }

    /** $action: approve | approve_cash | complete | reject. */
    public function reviewRefund(string $refundId, string $action, ?string $note = null): array
    {
        $result = $this->call('select public.admin_portal_review_refund(?::text, ?::text, ?::text)::text as r', [$refundId, $action, $note]);
        $this->forget();

        return $result ?? [];
    }

    public function adjustLoyalty(string $firebaseUid, int $points, string $reason, string $requestKey): array
    {
        return $this->call('select public.owner_adjust_loyalty_points(?::text, ?::int, ?::text, ?::text)::text as r',
            [$firebaseUid, $points, $reason, $requestKey]) ?? [];
    }

    public function updateLoyaltySettings(float $earnPesosPerPoint, float $pointsPerPeso, float $maxDiscountPercent): array
    {
        return $this->call('select public.owner_update_loyalty_settings(?::numeric, ?::numeric, ?::numeric)::text as r',
            [$earnPesosPerPoint, $pointsPerPeso, $maxDiscountPercent]) ?? [];
    }

    public function setProductActive(string $productId, bool $active): void
    {
        $this->call('select public.staff_set_product_active(?::uuid, ?::boolean)::text as r', [$productId, $active ? 'true' : 'false']);
    }

    // ---- RFID loyalty cards (migration 20261011000000_loyalty_cards.sql) ---------------------

    /** A tapped card: ['status' => active|blocked|replaced|unregistered, 'card' => [...], 'customer' => [...]]. */
    public function lookupCard(string $cardUid): array
    {
        return $this->call('select public.staff_lookup_card(?::text)::text as r', [$cardUid]) ?? [];
    }

    /** Exact match on a tapped card, printed label, phone or e-mail (never a partial search). */
    public function lookupCustomer(string $query): array
    {
        return $this->call('select public.staff_lookup_customer(?::text)::text as r', [$query]) ?? [];
    }

    public function customerCards(string $firebaseUid): array
    {
        return $this->call('select public.staff_customer_cards(?::text)::text as r', [$firebaseUid]) ?? [];
    }

    /** Owner only. */
    public function listCards(?string $query, ?string $status): array
    {
        return $this->call('select public.owner_list_loyalty_cards(?::text, ?::text, 200)::text as r', [$query, $status]) ?? [];
    }

    public function registerCard(string $cardUid, string $customerUid, string $requestKey): array
    {
        return $this->call('select public.staff_register_loyalty_card(?::text, ?::text, ?::text)::text as r',
            [$cardUid, $customerUid, $requestKey]) ?? [];
    }

    public function replaceCard(string $customerUid, string $newCardUid, string $reason, string $requestKey): array
    {
        return $this->call('select public.staff_replace_loyalty_card(?::text, ?::text, ?::text, ?::text)::text as r',
            [$customerUid, $newCardUid, $reason, $requestKey]) ?? [];
    }

    public function blockCard(string $cardId, string $reason): array
    {
        return $this->call('select public.staff_block_loyalty_card(?::uuid, ?::text)::text as r', [$cardId, $reason]) ?? [];
    }

    /** Owner only. */
    public function unblockCard(string $cardId): array
    {
        return $this->call('select public.owner_unblock_loyalty_card(?::uuid)::text as r', [$cardId]) ?? [];
    }

    // ---- suppliers + purchase receipts (migration 20261011010000) ----------------------------

    public function suppliers(bool $includeInactive = false): array
    {
        return $this->call('select public.staff_list_suppliers(?::boolean)::text as r', [$includeInactive ? 'true' : 'false']) ?? [];
    }

    public function saveSupplier(?string $id, array $d): string
    {
        return (string) $this->call('select to_jsonb(public.staff_save_supplier(?::uuid, ?::text, ?::text, ?::text, ?::text, ?::text, ?::text, ?::boolean))::text as r',
            [$id, $d['name'], $d['contact_person'] ?? null, $d['phone'] ?? null, $d['email'] ?? null, $d['address'] ?? null,
                $d['tin'] ?? null, ($d['is_active'] ?? true) ? 'true' : 'false']);
    }

    public function purchaseReceipts(?string $branchId, ?string $status): array
    {
        return $this->take("receipts:$branchId:$status", fn () => $this->call('select public.staff_list_purchase_receipts(?::uuid, ?::text, 200)::text as r', [$branchId, $status]) ?? []);
    }

    public function purchaseReceipt(string $id): array
    {
        return $this->call('select public.staff_get_purchase_receipt(?::uuid)::text as r', [$id]) ?? [];
    }

    /** Creates ($id null) or replaces a draft. $lines: list of line arrays (see the SQL function). */
    public function savePurchaseReceipt(?string $id, string $branchId, ?string $supplierId, ?string $invoiceNo, ?string $invoiceDate,
        array $lines, string $source = 'manual', ?string $ocrText = null, ?float $ocrConfidence = null,
        ?string $documentPath = null, ?string $notes = null, ?float $invoiceTotal = null): array
    {
        return $this->call('select public.staff_save_purchase_receipt(?::uuid, ?::uuid, ?::uuid, ?::text, ?::date, ?::jsonb, ?::text, ?::text, ?::numeric, ?::text, ?::text, ?::numeric)::text as r',
            [$id, $branchId, $supplierId, $invoiceNo, $invoiceDate, json_encode(array_values($lines), JSON_THROW_ON_ERROR),
                $source, $ocrText, $ocrConfidence, $documentPath, $notes, $invoiceTotal]) ?? [];
    }

    public function approvePurchaseReceipt(string $id, string $requestKey): array
    {
        return $this->call('select public.staff_approve_purchase_receipt(?::uuid, ?::text)::text as r', [$id, $requestKey]) ?? [];
    }

    public function cancelPurchaseReceipt(string $id, string $reason): array
    {
        return $this->call('select public.staff_cancel_purchase_receipt(?::uuid, ?::text)::text as r', [$id, $reason]) ?? [];
    }

    // ---- HitPay refund attempts (migration 20261011020000) -----------------------------------

    public function beginGatewayRefund(string $refundId): array
    {
        return $this->call('select public.staff_begin_gateway_refund(?::text)::text as r', [$refundId]) ?? [];
    }

    /** $status: succeeded | pending | failed */
    public function finishGatewayRefund(string $attemptId, string $status, ?string $gatewayRefundId, ?string $error): array
    {
        $r = $this->call('select public.staff_finish_gateway_refund(?::uuid, ?::text, ?::text, ?::text)::text as r',
            [$attemptId, $status, $gatewayRefundId, $error]) ?? [];
        $this->forget();

        return $r;
    }

    public function abandonGatewayRefund(string $attemptId, string $note): array
    {
        return $this->call('select public.staff_abandon_gateway_refund(?::uuid, ?::text)::text as r', [$attemptId, $note]) ?? [];
    }

    public function gatewayAttempts(string $refundId): array
    {
        return $this->call('select public.staff_refund_gateway_attempts(?::text)::text as r', [$refundId]) ?? [];
    }
}

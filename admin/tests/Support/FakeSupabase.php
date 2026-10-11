<?php

namespace Tests\Support;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Services\Supabase\SupabaseGateway;
use Closure;

/**
 * TEST-ONLY stand-in for the Supabase database behind SupabaseGateway, for feature tests that
 * run with DATA_SOURCE=supabase without a Postgres server.
 *
 * It answers the SQL functions the portal calls the way the real ones do FOR THE CALLING UID:
 * get_my_staff_context() from the staff fixtures, branch scoping (owner: every branch, staff:
 * their own; a foreign p_branch_id is refused), owner-only functions refuse anyone else.
 * Every call is recorded (uid, function, bindings) so tests can check who asked for what.
 * The real SQL is exercised end to end in SupabaseIntegrationTest.
 */
class FakeSupabase extends SupabaseGateway
{
    public array $branches = [];
    /** uid => staff_members row */
    public array $staff = [];
    /** raw admin_portal_orders rows */
    public array $orders = [];
    /** branch id => stock items (admin_portal_stock shape) */
    public array $stock = [];
    /** uid => drivers row (owner_all_users returns them; the website drops them) */
    public array $drivers = [];
    /** uid => customer_profiles row with its order figures (owner_all_users shape) */
    public array $customers = [];
    /** uid => overview metrics merged into owner_staff_overview rows */
    public array $activity = [];
    /** business_settings row (get_business_settings shape, without branches); null values = Not set */
    public array $settings = [
        'restock_threshold_default' => null, 'stock_low_ratio' => null, 'stock_plenty_ratio' => null,
        'sales_low_ratio' => null, 'sales_high_ratio' => null, 'default_daily_sales_target' => null,
        'healthy_margin_percent' => null, 'expiry_alert_days' => null, 'low_stock_badge_qty' => null, 'carried_over' => false,
        'loyalty' => ['earn_pesos_per_point' => null, 'points_per_peso' => null, 'max_discount_percent' => null],
        'online_payment_enabled' => false, 'online_payment_disabled_message' => 'Online payment is temporarily unavailable.',
    ];
    /** [['uid', 'fn', 'bindings', 'claims']] */
    public array $calls = [];
    public bool $offline = false;
    /** SQL functions that "do not exist yet" (a migration not run): calling them fails with SQLSTATE 42883. */
    public array $missing = [];

    public static function missingFunction(string $fn): BackendUnavailableException
    {
        $pdo = new \PDOException("function public.$fn() does not exist");
        $pdo->errorInfo = ['42883', 7, "ERROR:  function public.$fn() does not exist"];

        return new BackendUnavailableException('The Melai Nuts database returned an unexpected error.', 0,
            new \Illuminate\Database\QueryException('supabase', "select public.$fn()", [], $pdo));
    }

    public static function make(): self
    {
        $f = new self;
        $f->branches = [['id' => 'b-cal', 'name' => 'Calamba Branch'], ['id' => 'b-lb', 'name' => 'Los Baños Branch']];
        $f->staff = [
            'uid-owner' => ['firebase_uid' => 'uid-owner', 'full_name' => 'Melai Owner', 'email' => 'owner@melainuts.test', 'role' => 'owner', 'branch_id' => null, 'account_status' => 'active'],
            'uid-cal' => ['firebase_uid' => 'uid-cal', 'full_name' => 'Cora Cashier', 'email' => 'cora@melainuts.test', 'role' => 'staff', 'branch_id' => 'b-cal', 'account_status' => 'active'],
            'uid-lb' => ['firebase_uid' => 'uid-lb', 'full_name' => 'Lito Cashier', 'email' => 'lito@melainuts.test', 'role' => 'staff', 'branch_id' => 'b-lb', 'account_status' => 'active'],
        ];
        $f->activity = [
            'uid-cal' => ['pos_transactions' => 4, 'pos_sales' => 1200, 'pos_refunds' => 100, 'shifts_opened' => 1, 'open_shift' => true, 'last_activity_at' => now()->subMinutes(5)->toIso8601String()],
            'uid-lb' => ['pos_transactions' => 2, 'pos_sales' => 500, 'pos_refunds' => 0, 'shifts_opened' => 1, 'open_shift' => false, 'last_activity_at' => now()->subHour()->toIso8601String()],
        ];
        $f->drivers = [
            'uid-drv' => ['firebase_uid' => 'uid-drv', 'full_name' => 'Dario Rider', 'email' => 'dario@melainuts.test', 'phone' => '09170000001',
                'branch_id' => 'b-cal', 'vehicle' => 'Motorcycle', 'account_status' => 'active', 'is_available' => true, 'active_runs' => 1],
        ];
        $f->customers = [
            'uid-cus' => ['firebase_uid' => 'uid-cus', 'full_name' => 'Carla Customer', 'email' => 'carla@example.test', 'phone' => '09181234567',
                'card_number' => 'CARD-0042', 'branch_id' => 'b-lb', 'created_at' => now()->subDays(3)->toIso8601String(),
                'orders' => 3, 'paid_total' => 1250.5, 'last_order_at' => now()->subDay()->toIso8601String(), 'points_balance' => 25],
        ];
        $f->addOrder('ORD-CAL-1', 'b-cal', 700);
        $f->addOrder('ORD-LB-1', 'b-lb', 450);
        $f->stock = [
            'b-cal' => [['product_name' => 'Garlic Peanuts', 'variant_label' => 'Regular', 'quantity' => 3, 'restock_threshold' => 10, 'carried' => true]],
            'b-lb' => [['product_name' => 'Adobo Peanuts', 'variant_label' => 'Regular', 'quantity' => 40, 'restock_threshold' => 10, 'carried' => true]],
        ];

        return $f;
    }

    public function addOrder(string $id, string $branch, float $total, string $payment = 'success'): void
    {
        $at = now()->subSeconds(5)->toIso8601String();
        $this->orders[] = [
            'id' => $id, 'branch_id' => $branch, 'branch_name' => $this->branchName($branch), 'total' => $total, 'status' => 'completed',
            'created_at' => $at, 'items' => [['product_name' => 'Garlic Peanuts', 'variant_label' => 'Regular', 'quantity' => 1]],
            'payment' => ['id' => "pay-$id", 'method' => 'cash', 'status' => $payment, 'reference_number' => null, 'updated_at' => $at],
            'refund' => null, 'customer_name' => 'Walk-in', 'customer_uid' => null, 'is_pos' => true, 'is_delivery' => false, 'payment_label' => 'Cash',
        ];
    }

    public function calledFunctions(?string $uid = null): array
    {
        return array_column(array_filter($this->calls, fn ($c) => $uid === null || $c['uid'] === $uid), 'fn');
    }

    public function actingAs(string $firebaseUid, Closure $work, array $verified = []): mixed
    {
        // Raw SQL (branch map positions): not modelled; the portal treats it as "no positions".
        throw new BackendUnavailableException('FakeSupabase answers SQL functions only.');
    }

    /** portal_staff_uid_for_email(): the website server's lookup of a UID by e-mail and role. */
    public function staffUidForEmail(string $email, string $role): array
    {
        if ($this->offline) {
            throw new BackendUnavailableException('The Melai Nuts database could not be reached. Please try again in a moment.');
        }
        $this->calls[] = ['uid' => null, 'fn' => 'portal_staff_uid_for_email', 'bindings' => [$email, $role], 'claims' => []];
        if (in_array('portal_staff_uid_for_email', $this->missing, true)) {
            throw self::missingFunction('portal_staff_uid_for_email');
        }
        $rows = array_values(array_filter($this->staff, fn ($s) => mb_strtolower($s['email']) === mb_strtolower($email) && $s['role'] === $role));

        return match (count($rows)) {
            0 => ['status' => 'none'],
            1 => ['status' => 'found', 'firebase_uid' => $rows[0]['firebase_uid'], 'account_status' => $rows[0]['account_status']],
            default => ['status' => 'ambiguous', 'count' => count($rows)],
        };
    }

    /**
     * SupabaseRepository::prefetch() batches: "select json_build_object('p0', public.f(?..), ...)".
     * Each part is answered (and recorded in $calls) as if it had been called on its own; the
     * batch fails as a whole if one part fails, like the real single statement does.
     * Returns null for SQL that is not a batch.
     */
    protected function splitBatch(string $sql, array $bindings): ?array
    {
        if (! str_contains($sql, "json_build_object('p0'")) {
            return null;
        }
        preg_match_all("/'(p\\d+)', public\\.(\\w+)\\(([^)]*)\\)/", $sql, $m, PREG_SET_ORDER);
        $parts = [];
        $offset = 0;
        foreach ($m as [, $alias, $fn, $args]) {
            $n = substr_count($args, '?');
            $parts[] = [$alias, "select public.$fn($args)::text as r", array_slice($bindings, $offset, $n)];
            $offset += $n;
        }

        return $parts;
    }

    public function call(string $firebaseUid, string $sql, array $bindings = [], array $verified = []): mixed
    {
        if (($parts = $this->splitBatch($sql, $bindings)) !== null) {
            $out = [];
            foreach ($parts as [$alias, $one, $b]) {
                $out[$alias] = $this->call($firebaseUid, $one, $b, $verified);
            }

            return $out;
        }
        if ($this->offline) {
            throw new BackendUnavailableException('The Melai Nuts database could not be reached. Please try again in a moment.');
        }
        preg_match('/public\.(\w+)\(/', $sql, $m);
        $fn = $m[1] ?? $sql;
        $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];
        if (in_array($fn, $this->missing, true)) {
            throw self::missingFunction($fn);
        }
        $me = $this->staff[$firebaseUid] ?? null;

        if ($fn === 'get_my_staff_context') {
            return $this->context($me);
        }
        if ($fn === 'staff_registration_for_my_email') {
            $row = collect($this->staff)->first(fn ($s) => mb_strtolower($s['email']) === mb_strtolower((string) ($verified['email'] ?? '')));

            return $row ? ['found' => true, 'same_uid' => $row['firebase_uid'] === $firebaseUid, 'role' => $row['role'], 'account_status' => $row['account_status']] : ['found' => false];
        }

        // Everything else needs an active staff / owner caller (public._require_staff).
        if (! $me || $me['account_status'] !== 'active') {
            throw new BackendActionException('Your staff account is not active.');
        }
        $allowed = $me['role'] === 'owner' ? array_column($this->branches, 'id') : [$me['branch_id']];
        $only = function (?string $branch) use ($allowed) {
            if ($branch !== null && ! in_array($branch, $allowed, true)) {
                throw new BackendActionException('You can only work in your assigned branch.');
            }

            return $branch ? [$branch] : $allowed;
        };

        return match ($fn) {
            'admin_portal_orders' => array_values(array_filter($this->orders, fn ($o) => in_array($o['branch_id'], $only($bindings[2] ?? null), true))),
            'admin_portal_stock' => array_map(fn ($b) => ['branch_id' => $b, 'items' => $this->stock[$b] ?? []], $allowed),
            'sales_overview' => $this->salesOverview($only($bindings[2] ?? null), (string) $bindings[0], (string) $bindings[1]),
            'admin_portal_loyalty_summary' => ['members' => 3, 'issued_month' => 120, 'redeemed_month' => 40],
            'staff_cashier_daily_summary' => ['branch_id' => $only($bindings[0])[0], 'date' => $bindings[1], 'cashiers' => [], 'shifts' => [],
                'totals' => ['transaction_count' => 0, 'gross_sales' => 0, 'discounts' => 0, 'refunds' => 0, 'void_count' => 0, 'net_sales' => 0, 'cash_sales' => 0, 'non_cash_sales' => 0]],
            'owner_staff_overview' => $this->overview($me, $bindings[2] ?? null),
            'owner_all_users' => $me['role'] === 'owner' ? $this->allUsers($bindings[0] ?? null, (int) ($bindings[1] ?? 500))
                : throw new BackendActionException('Only an active owner can do this.'),
            'admin_portal_loyalty_members' => array_values(array_map(fn ($c) => ['id' => $c['firebase_uid'], 'name' => $c['full_name'], 'email' => $c['email'],
                'card_number' => $c['card_number'], 'balance' => $c['points_balance']], $this->matchingCustomers($bindings[0] ?? null))),
            // No loyalty_cart_settings row until the owner saves rules (a new database has none).
            'admin_portal_loyalty_settings' => $this->settings['loyalty']['earn_pesos_per_point'] === null ? null : $this->settings['loyalty'],
            'get_business_settings' => $this->settings + ['branches' => array_values(array_map(fn ($b) => $b + [
                'address' => null, 'contact_phone' => null, 'operating_hours' => null, 'is_active' => true, 'supports_delivery' => false,
                'supports_pickup' => true, 'delivery_fee' => 0, 'daily_sales_target' => null, 'is_warehouse' => false], array_filter($this->branches, fn ($b) => in_array($b['id'], $allowed, true))))],
            'owner_update_business_settings' => $me['role'] === 'owner' ? $this->updateSettings(json_decode((string) $bindings[0], true) ?: [], $allowed)
                : throw new BackendActionException('Only an active owner can do this.'),
            'owner_save_branch' => $me['role'] === 'owner' ? $this->saveBranch($bindings) : throw new BackendActionException('Only an active owner can do this.'),
            'owner_set_branch_warehouse' => $me['role'] === 'owner' ? $this->setWarehouse((string) $bindings[0], $bindings[1] === 'true')
                : throw new BackendActionException('Only an active owner can do this.'),
            'admin_portal_staff_directory' => $me['role'] === 'owner'
                ? array_values(array_map(fn ($s) => $s + ['branch_name' => $this->branchName($s['branch_id']), 'is_active' => $s['account_status'] === 'active'], $this->staff))
                : throw new BackendActionException('Only an active owner can do this.'),
            default => throw new BackendUnavailableException("FakeSupabase has no answer for {$fn}()."),
        };
    }

    private function updateSettings(array $values, array $allowed): array
    {
        foreach ($values as $k => $v) {
            if (! array_key_exists($k, $this->settings) || $k === 'loyalty') {
                throw new BackendActionException("Unknown setting: $k");
            }
            $this->settings[$k] = $v;
        }
        $this->settings['carried_over'] = false;

        return $this->call('uid-owner', 'select public.get_business_settings()::text as r');
    }

    private function setWarehouse(string $id, bool $on): array
    {
        foreach ($this->branches as $i => $b) {
            if ($b['id'] === $id) {
                $this->branches[$i]['is_warehouse'] = $on;
                if ($on) {
                    $this->branches[$i]['supports_delivery'] = $this->branches[$i]['supports_pickup'] = false;
                }
            }
        }

        return ['id' => $id, 'is_warehouse' => $on];
    }

    private function saveBranch(array $b): array
    {
        [$id, $name, $address, $phone, $hours, $fee, $target, $delivery, $pickup, $active] = $b;
        if ($fee === null) {
            throw new BackendActionException('Enter the delivery fee (0 if delivery is free).');
        }
        $row = ['name' => $name, 'address' => $address, 'contact_phone' => $phone, 'operating_hours' => $hours,
            'delivery_fee' => (float) $fee, 'daily_sales_target' => $target === null ? null : (float) $target,
            'supports_delivery' => $delivery === 'true', 'supports_pickup' => $pickup === 'true', 'is_active' => $active === 'true'];
        if ($id === null) {
            $id = 'b-new-'.count($this->branches);
            $this->branches[] = ['id' => $id] + $row;
        } else {
            foreach ($this->branches as $i => $existing) {
                if ($existing['id'] === $id) {
                    $this->branches[$i] = ['id' => $id] + $row + ['is_warehouse' => $existing['is_warehouse'] ?? false];
                }
            }
        }

        return ['id' => $id];
    }

    /** sales_overview() shape from the fixture orders, for the caller's branches (see SalesFixture). */
    private function salesOverview(array $branchIds, string $from, string $to): array
    {
        $day = fn ($at) => \Carbon\Carbon::parse($at)->setTimezone('Asia/Manila')->toDateString();
        $rows = array_map(fn ($o) => [
            'branch' => $o['branch_id'], 'day' => $day($o['created_at']),
            'paid' => in_array($o['payment']['status'] ?? null, ['success', 'refunded'], true), 'gross' => (float) $o['total'],
            'refund' => ($o['refund']['status'] ?? null) === 'completed' ? (float) $o['refund']['amount'] : 0.0,
            'refund_day' => isset($o['refund']['completed_at']) ? $day($o['refund']['completed_at']) : $day($o['created_at']),
            'pending_refund' => in_array($o['refund']['status'] ?? null, ['pending', 'approved', 'processing'], true) ? (float) $o['refund']['amount'] : 0.0,
            'method' => $o['payment']['method'] ?? 'cash', 'channel' => ($o['is_pos'] ?? false) ? 'pos' : (($o['is_delivery'] ?? false) ? 'delivery' : 'pickup'),
        ], array_values(array_filter($this->orders, fn ($o) => in_array($o['branch_id'], $branchIds, true))));

        return SalesFixture::overview($rows, $from, $to, array_values(array_filter($this->branches, fn ($b) => in_array($b['id'], $branchIds, true))));
    }

    private function allUsers(?string $search, int $limit): array
    {
        $customers = $this->matchingCustomers($search);

        return [
            'staff' => array_values(array_map(fn ($s) => $s + ['branch_name' => $this->branchName($s['branch_id']), 'is_active' => $s['account_status'] === 'active'], $this->staff)),
            'drivers' => array_values(array_map(fn ($d) => $d + ['branch_name' => $this->branchName($d['branch_id'])], $this->drivers)),
            'customers' => array_slice(array_map(fn ($c) => $c + ['branch_name' => $this->branchName($c['branch_id'])], $customers), 0, max(1, $limit)),
            'customers_total' => count($customers),
        ];
    }

    private function matchingCustomers(?string $search): array
    {
        $q = mb_strtolower(trim((string) $search));

        return array_values(array_filter($this->customers, fn ($c) => $q === ''
            || str_contains(mb_strtolower($c['full_name'].' '.$c['email'].' '.$c['phone'].' '.$c['card_number']), $q)));
    }

    private function context(?array $me): array
    {
        if (! $me) {
            return ['status' => 'not_provisioned'];
        }
        if ($me['account_status'] !== 'active') {
            return ['status' => $me['account_status'] === 'suspended' ? 'suspended' : 'inactive'];
        }
        $branches = $me['role'] === 'owner' ? $this->branches : array_values(array_filter($this->branches, fn ($b) => $b['id'] === $me['branch_id']));

        return ['status' => 'active', 'profile' => $me + ['branch_name' => $this->branchName($me['branch_id']), 'is_active' => true],
            'authorized_branches' => $branches];
    }

    private function overview(array $me, ?string $branch): array
    {
        if ($me['role'] !== 'owner') {
            throw new BackendActionException('Only an active owner can do this.');
        }

        return array_values(array_map(function ($s) {
            $a = $this->activity[$s['firebase_uid']] ?? [];
            $sales = $a['pos_sales'] ?? 0;
            $refunds = $a['pos_refunds'] ?? 0;

            return $s + ['branch_name' => $this->branchName($s['branch_id']), 'is_active' => $s['account_status'] === 'active',
                'pos_transactions' => $a['pos_transactions'] ?? 0, 'pos_sales' => $sales, 'pos_refunds' => $refunds, 'pos_net_sales' => $sales - $refunds,
                'shifts_opened' => $a['shifts_opened'] ?? 0, 'open_shift' => $a['open_shift'] ?? false, 'last_activity_at' => $a['last_activity_at'] ?? null];
        }, array_filter($this->staff, fn ($s) => $branch === null || $s['branch_id'] === $branch)));
    }

    private function branchName(?string $id): ?string
    {
        return collect($this->branches)->firstWhere('id', $id)['name'] ?? null;
    }
}

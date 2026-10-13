<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
use Illuminate\Contracts\Auth\Authenticatable;
use PHPUnit\Framework\Attributes\Group;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/**
 * End-to-end tests of the admin portal against a real Postgres that has the Melai Nuts
 * Supabase schema + migrations (built by tests/Supabase/prepare-test-db.sh).
 *
 * "App" actions (customer checkout, refund requests) are made the way the Flutter app makes
 * them: calling the same SQL functions as the `authenticated` role with a Firebase UID.
 * The portal is exercised through real HTTP requests with DATA_SOURCE=supabase, connected
 * as the unprivileged `melai_admin_portal` role.
 *
 * Skipped unless SUPABASE_TEST_ADMIN_URL and SUPABASE_TEST_PORTAL_URL are set.
 */
#[Group('supabase')]
class SupabaseIntegrationTest extends TestCase
{
    use RefreshDatabase;

    private string $sfx;
    private array $fx = [];
    private FakeFirebase $fb;
    /** false = actingAs() without a Firebase sign-in in the session (legacy local-password login). */
    private bool $withFirebaseSession = true;

    protected function setUp(): void
    {
        parent::setUp();
        $admin = env('SUPABASE_TEST_ADMIN_URL');
        $portal = env('SUPABASE_TEST_PORTAL_URL');
        if (! $admin || ! $portal) {
            $this->markTestSkipped('Set SUPABASE_TEST_ADMIN_URL and SUPABASE_TEST_PORTAL_URL (see tests/Supabase/prepare-test-db.sh).');
        }

        // These tests are about the database; re-entering the password before refunds / points
        // (ConfirmRecentPassword) is tested in PasswordConfirmTest.
        $this->withSession([\App\Http\Middleware\ConfirmRecentPassword::SESSION_KEY => time()]);

        config([
            'melai.data_source' => 'supabase',
            'melai.dashboard.cache_seconds' => 0, // every request reads the database; the cache has its own test
            'database.connections.supabase' => ['driver' => 'pgsql', 'url' => $portal, 'sslmode' => 'disable', 'charset' => 'utf8', 'prefix' => '', 'search_path' => 'public'],
            'database.connections.supabase_admin' => ['driver' => 'pgsql', 'url' => $admin, 'sslmode' => 'disable', 'charset' => 'utf8', 'prefix' => '', 'search_path' => 'public'],
        ]);
        DB::purge('supabase');
        DB::purge('supabase_admin');

        $this->sfx = strtolower(Str::random(8));
        $this->seedApp();

        // Firebase Authentication of the app (fake, real RS256 tokens): the owner and staff A have app accounts.
        $this->fb = (new FakeFirebase)->install();
        $this->fb->addAccount("owner-{$this->sfx}@test.local", $this->fx['owner'], 'Owner#Pass1');
        $this->fb->addAccount("staff-a-{$this->sfx}@test.local", $this->fx['staff_a'], 'Staff#Pass1');
        $this->fb->profiles[$this->fx['owner']] = ['role' => 'owner', 'email' => "owner-{$this->sfx}@test.local", 'isActive' => true];
    }

    /**
     * Signed in to the website AND to the app account (Firebase ID token in the session), the way a
     * real login is. Pages that act as the app account need both.
     */
    public function actingAs(Authenticatable $user, $guard = null)
    {
        parent::actingAs($user, $guard);
        if ($this->withFirebaseSession && $user instanceof User && filled($user->firebase_uid)) {
            $this->withSession($this->fb->sessionFor($user));
        }

        return $this;
    }

    // ---- fixtures: written as the database owner, like the one-time SQL bootstrap ----------

    private function db()
    {
        return DB::connection('supabase_admin');
    }

    /** Run SQL as an app user (customer or staff), exactly like the Flutter app through Supabase. */
    private function asAppUser(string $uid, string $sql, array $bindings = []): mixed
    {
        return $this->db()->transaction(function ($db) use ($uid, $sql, $bindings) {
            $db->select("select set_config('request.jwt.claims', ?, true)", [json_encode(['sub' => $uid, 'role' => 'authenticated', 'email' => "$uid@test.local", 'email_verified' => true])]);
            $db->statement('set local role authenticated');
            $row = (array) $db->selectOne($sql, $bindings);

            return reset($row);
        });
    }

    private function seedApp(): void
    {
        $s = $this->sfx;
        $db = $this->db();
        foreach (['a' => "IT-$s Calamba", 'b' => "IT-$s Los Banos"] as $k => $name) {
            $this->fx["branch_$k"] = $db->selectOne('insert into public.branches (name, address, delivery_fee) values (?, ?, 30) returning id', [$name, 'addr'])->id;
            $this->fx["branch_{$k}_name"] = $name;
        }
        $cat = $db->selectOne("insert into public.product_categories (label) values (?) returning id", ["IT-$s Nuts"])->id;
        $this->fx['product'] = $db->selectOne("insert into public.products (category_id, name, price, unit) values (?, ?, 100, 'pack') returning id", [$cat, "IT-$s Garlic Peanuts"])->id;
        $this->fx['variant'] = $db->selectOne("insert into public.product_variants (product_id, label, price) values (?, 'Regular', 100) returning id", [$this->fx['product']])->id;
        foreach (['a', 'b'] as $k) {
            $db->insert('insert into public.branch_inventory (branch_id, product_id, variant_id, quantity) values (?, ?, ?, 50)',
                [$this->fx["branch_$k"], $this->fx['product'], $this->fx['variant']]);
        }

        $this->fx['owner'] = "it-own-$s";
        $this->fx['staff_a'] = "it-sa-$s";
        $this->fx['customer'] = "it-c-$s";
        $db->insert("insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory, can_review_refunds)
                     values (?, 'IT Owner', ?, 'owner', null, 'active', true, true),
                            (?, 'IT Staff A', ?, 'staff', ?, 'active', true, false)",
            [$this->fx['owner'], "owner-$s@test.local", $this->fx['staff_a'], "staff-a-$s@test.local", $this->fx['branch_a']]);
        $db->insert("insert into public.customer_profiles (firebase_uid, full_name, email, phone, rfid_card_number) values (?, ?, ?, '0917', ?)",
            [$this->fx['customer'], "IT Customer $s", "cust-$s@test.local", "CARD-$s"]);
        // Test fixture: loyalty rules (a new database has none; the owner sets them).
        $db->statement("insert into public.loyalty_cart_settings (id, points_per_peso, max_discount_percent, earn_pesos_per_point) values ('default', 1, 50, 50)
                        on conflict (id) do update set points_per_peso = 1, max_discount_percent = 50, earn_pesos_per_point = 50");
    }

    /** Customer checkout through the app's own functions. Returns the order id. */
    private function placeOrder(string $branch, string $method = 'Cash on Counter Pickup', int $qty = 2): string
    {
        $cart = json_decode($this->asAppUser($this->fx['customer'],
            "select public.sync_customer_cart(?::uuid, jsonb_build_array(jsonb_build_object('product_id', ?::text, 'variant_id', ?::text, 'quantity', ?::int)), null, false)::text",
            [$this->fx["branch_$branch"], $this->fx['product'], $this->fx['variant'], $qty]), true)['cart_id'];

        // Online payment is switched off by default (migration 20261017000000); tests of online-paid
        // orders switch it on for that one order and back off right after.
        $online = in_array($method, ['Online Payment (GCash, Maya, Card)', 'GCash E-Wallet', 'Maya / Credit Card'], true);
        if ($online) {
            $this->db()->update("update public.payment_settings set online_payment_enabled = true where id = 'default'");
        }
        try {
            return $this->asAppUser($this->fx['customer'], 'select public.place_order(?::uuid, false, null, ?, \'\', ?)', [$cart, $method, Str::uuid()->toString()]);
        } finally {
            if ($online) {
                $this->db()->update("update public.payment_settings set online_payment_enabled = false where id = 'default'");
            }
        }
    }

    private function completeOrder(string $orderId, ?string $reference = null): void
    {
        $this->asAppUser($this->fx['owner'], 'select public.staff_confirm_payment(?, ?)::text', [$orderId, $reference]);
        foreach (['confirmed', 'preparing', 'readyForPickup', 'completed'] as $st) {
            $this->asAppUser($this->fx['owner'], 'select public.staff_update_order_status(?, ?)::text', [$orderId, $st]);
        }
    }

    private function requestRefund(string $orderId, int $qty = 2): string
    {
        return $this->asAppUser($this->fx['customer'],
            "select public.request_refund(?, 'Damaged pack', '', jsonb_build_array(jsonb_build_object('product_name', ?::text, 'variant_label', 'Regular', 'quantity', ?::int)))",
            [$orderId, "IT-{$this->sfx} Garlic Peanuts", $qty]);
    }

    private function portalAdmin(bool $linked = true): User
    {
        $u = User::factory()->create(['email' => "owner-{$this->sfx}@test.local", 'role' => 'admin', 'has_access' => true]);
        if ($linked) {
            $u->forceFill(['staff_uid' => $this->fx['owner'], 'firebase_uid' => $this->fx['owner']])->save();
        }

        return $u;
    }

    private function portalStaff(): User
    {
        $u = User::factory()->create(['email' => "staff-a-{$this->sfx}@test.local", 'role' => 'staff', 'has_access' => true]);
        $u->forceFill(['staff_uid' => $this->fx['staff_a'], 'firebase_uid' => $this->fx['staff_a']])->save();

        return $u;
    }

    // ---- linking -------------------------------------------------------------------------

    public function test_melai_admin_with_the_website_password_acts_as_the_owner_found_by_email(): void
    {
        config(['melai.admin.staff_uid' => null]);
        // The seeded admin: website password, no Firebase identity, no staff_uid yet. Real database lookup.
        $admin = User::factory()->create(['email' => "owner-{$this->sfx}@test.local", 'role' => 'admin', 'has_access' => true, 'password' => 'Seed#Pass1']);
        $this->fb->accounts = []; // no Firebase account involved at all

        $this->post('/login', ['email' => $admin->email, 'password' => 'Seed#Pass1'])->assertRedirect(route('dashboard'))->assertSessionHasNoErrors();
        $this->assertSame($this->fx['owner'], $admin->fresh()->staff_uid);
        $this->assertNull($admin->fresh()->firebase_uid);

        $this->withFirebaseSession = false;
        $this->get('/dashboard')->assertOk()->assertSee($this->fx['branch_a_name'])->assertSee($this->fx['branch_b_name'])
            ->assertSee('IT Staff A')->assertDontSee('Account not linked')->assertDontSee('Link my app account');

        // ADMIN_STAFF_UID that is not an owner: refused on the login page, nothing linked.
        $this->post('/logout');
        $other = User::factory()->create(['email' => "boss-{$this->sfx}@test.local", 'role' => 'admin', 'has_access' => true, 'password' => 'Boss#Pass1']);
        config(['melai.admin.staff_uid' => $this->fx['staff_a']]);
        $this->post('/login', ['email' => $other->email, 'password' => 'Boss#Pass1'])->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->assertNull($other->fresh()->staff_uid);
    }

    public function test_link_command_verifies_with_supabase(): void
    {
        $admin = $this->portalAdmin(linked: false);

        $this->artisan('melai:link-staff', ['email' => $admin->email, 'uid' => $this->fx['staff_a']])
            ->expectsOutputToContain("does not match")->assertFailed();
        $this->artisan('melai:link-staff', ['email' => $admin->email, 'uid' => 'no-such-uid'])
            ->expectsOutputToContain('not registered')->assertFailed();
        $this->artisan('melai:link-staff', ['email' => $admin->email, 'uid' => $this->fx['owner']])
            ->expectsOutputToContain('Linked')->assertSuccessful();

        $this->assertSame($this->fx['owner'], $admin->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'account.staff_linked')->exists());
    }

    public function test_admin_cannot_link_staff_login_to_an_owner_account(): void
    {
        $admin = $this->portalAdmin();
        $staffLogin = User::factory()->create(['email' => "owner-x-{$this->sfx}@test.local", 'role' => 'staff', 'has_access' => true]);

        $this->actingAs($admin)->from('/admin/users')->post(route('admin.users.link', $staffLogin), ['staff_uid' => $this->fx['owner']])
            ->assertSessionHasErrors('staff_uid');
        $this->assertNull($staffLogin->fresh()->staff_uid);
    }

    public function test_deactivating_the_app_account_cuts_off_the_portal(): void
    {
        $admin = $this->portalAdmin();
        $this->actingAs($admin)->get('/dashboard')->assertOk();

        $this->db()->update("update public.staff_members set account_status = 'inactive' where firebase_uid = ?", [$this->fx['owner']]);
        $this->actingAs($admin)->get('/dashboard')->assertRedirect(route('login'));
        $this->assertGuest();
        $this->assertStringContainsString('deactivated', session('errors')->first('auth'));

        // Signing in again is refused on the login page with the same reason.
        $this->post('/login', ['email' => $admin->email, 'password' => 'Owner#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('deactivated', session('errors')->first('auth'));
        $this->assertGuest();
    }

    public function test_signed_in_owner_without_a_link_is_linked_automatically_on_the_next_page(): void
    {
        // The login is bound to the owner's Firebase account and holds a valid app sign-in, but has
        // no staff_uid yet (e.g. linked before this version, or unlinked by an admin): no manual step.
        $admin = $this->portalAdmin(linked: false);
        $admin->forceFill(['firebase_uid' => $this->fx['owner']])->save();

        $this->actingAs($admin)->get('/dashboard')->assertOk()
            ->assertSee($this->fx['branch_a_name'])->assertSee($this->fx['branch_b_name'])
            ->assertDontSee('Account not linked');
        $this->assertSame($this->fx['owner'], $admin->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'account.staff_linked')->exists());
        $this->get('/account/link')->assertRedirect('/dashboard'); // the old page is gone
    }

    public function test_login_refuses_wrong_role_or_foreign_registrations_with_the_reason_and_links_staff(): void
    {
        $admin = $this->portalAdmin(linked: false);
        $staffEmail = "staff-a-{$this->sfx}@test.local";
        // The admin's own Firebase account is registered in the app's staff registry as STAFF (wrong role for an admin login).
        $wrongRoleUid = "it-wr-{$this->sfx}";
        $this->db()->update('update public.staff_members set email = ? where firebase_uid = ?', ["old-owner-{$this->sfx}@test.local", $this->fx['owner']]);
        $this->db()->insert("insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values (?, 'Wrong Role', ?, 'staff', ?, 'active')",
            [$wrongRoleUid, $admin->email, $this->fx['branch_a']]);
        $this->fb->accounts = [];
        $this->fb->addAccount($admin->email, $wrongRoleUid, 'p1');
        $this->fb->addAccount($staffEmail, $this->fx['staff_a'], 'p2');

        $this->post('/login', ['email' => $admin->email, 'password' => 'p1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('Role not authorized', session('errors')->first('auth'));
        $this->assertStringContainsString('admin login, but your app account is a staff account', session('errors')->first('auth'));
        $this->assertGuest();
        $this->assertNull($admin->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'auth.autolink_failed')->exists());

        // A staff member's first sign-in creates nothing by hand: the existing staff login is bound and linked.
        $staffLogin = User::factory()->create(['email' => $staffEmail, 'role' => 'staff', 'has_access' => true]);
        $this->post('/login', ['email' => $staffEmail, 'password' => 'p2'])->assertRedirect(route('dashboard'));
        $this->assertSame($this->fx['staff_a'], $staffLogin->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'account.auto_linked')->where('user_id', $staffLogin->id)->exists());
        $this->post('/logout');

        // Same e-mail registered in the staff registry, but under ANOTHER Firebase account: precise reason, nothing linked.
        $other = "other-{$this->sfx}@test.local";
        $this->db()->insert("insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status) values (?, 'Old Entry', ?, 'staff', ?, 'active')",
            ["it-old-{$this->sfx}", $other, $this->fx['branch_a']]);
        $this->fb->addAccount($other, "it-new-{$this->sfx}", 'p3');
        $this->post('/login', ['email' => $other, 'password' => 'p3'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('under a different Firebase account', session('errors')->first('auth'));
        $this->assertGuest();
    }

    public function test_dashboard_kpis_match_the_database_and_follow_payments_and_refunds(): void
    {
        $admin = $this->portalAdmin();
        // The test database is shared by all tests, so compare before/after instead of absolute values.
        $before = $this->actingAs($admin)->get('/dashboard')->assertOk()->viewData('kpis');

        $paid = $this->placeOrder('a');
        $this->placeOrder('b');                  // stays unpaid: not revenue
        $this->completeOrder($paid);
        $total = (float) $this->db()->selectOne('select total from public.orders where id = ?', [$paid])->total;

        $after = $this->actingAs($admin)->get('/dashboard')->assertOk()->assertSee('Net sales')->viewData('kpis');
        $this->assertSame($before['orders'] + 2, $after['orders']);
        $this->assertSame($before['paid_orders'] + 1, $after['paid_orders']);
        $this->assertEqualsWithDelta($before['gross_sales'] + $total, $after['gross_sales'], 0.001);
        $this->assertEqualsWithDelta($before['net_sales'] + $total, $after['net_sales'], 0.001);
        $this->assertSame($before['payments_pending'] + 1, $after['payments_pending']);

        // A completed refund lowers net sales but not gross paid sales.
        $this->requestRefund($paid);
        $this->actingAs($admin)->post(route('admin.refunds.approve', $paid))->assertSessionHas('status'); // cash: one step
        $refundRow = $this->db()->selectOne('select status, amount from public.refund_requests where order_id = ?', [$paid]);
        $final = $this->actingAs($admin)->get('/dashboard')->assertOk()->viewData('kpis');
        $this->assertSame('completed', $refundRow->status, 'cash refunds complete in one step');
        $this->assertEqualsWithDelta($after['gross_sales'], $final['gross_sales'], 0.001);
        $this->assertEqualsWithDelta($after['refunds'] + (float) $refundRow->amount, $final['refunds'], 0.001);
        $this->assertEqualsWithDelta($after['net_sales'] - (float) $refundRow->amount, $final['net_sales'], 0.001);
    }

    public function test_dashboard_stock_ignores_products_a_branch_does_not_carry(): void
    {
        $db = $this->db();
        $cat = $db->selectOne('select category_id from public.products where id = ?', [$this->fx['product']])->category_id;
        $p = $db->selectOne("insert into public.products (category_id, name, price, unit) values (?, ?, 80, 'pack') returning id", [$cat, "IT-{$this->sfx} Only In A"])->id;
        $v = $db->selectOne("insert into public.product_variants (product_id, label, price) values (?, 'Regular', 80) returning id", [$p])->id;
        $db->insert('insert into public.branch_inventory (branch_id, product_id, variant_id, quantity) values (?, ?, ?, 0)', [$this->fx['branch_a'], $p, $v]);

        $stock = app(\App\Contracts\DataSource::class);
        $this->actingAs($this->portalAdmin());
        $all = $stock->stock();
        $names = fn ($branch) => array_column($all[$this->fx[$branch]] ?? [], 'product');

        $this->assertContains("IT-{$this->sfx} Only In A", $names('branch_a'), 'carried at A with 0 left: out of stock there');
        $this->assertNotContains("IT-{$this->sfx} Only In A", $names('branch_b'), 'never carried at B: not out of stock at B');
        $this->assertContains("IT-{$this->sfx} Garlic Peanuts", $names('branch_b'));
    }

    public function test_targets_are_only_shown_when_set_and_the_website_reads_no_map_positions(): void
    {
        $admin = $this->portalAdmin();
        $this->db()->statement("insert into public.business_settings (id) values ('default') on conflict (id) do nothing");
        $this->db()->update("update public.business_settings set default_daily_sales_target = null where id = 'default'");
        $this->db()->update('update public.branches set daily_sales_target = null where id in (?, ?)', [$this->fx['branch_a'], $this->fx['branch_b']]);
        \App\Services\AdminActions::bump();

        // No targets configured: no ratings, nothing invented. Branch coordinates are app-only data.
        $this->db()->update('update public.branches set latitude = 14.2117, longitude = 121.1653 where id = ?', [$this->fx['branch_a']]);
        $page = $this->actingAs($admin)->get('/dashboard')->assertOk()->assertSee('No target set')->assertDontSee('14.2117');
        $branches = collect($page->viewData('branches'))->keyBy('id');
        $this->assertArrayNotHasKey('lat', $branches[$this->fx['branch_a']]);
        $this->assertNull($branches[$this->fx['branch_a']]['daily_target']);

        // A target set by the owner (in the database) is used as it is.
        $this->db()->update('update public.branches set daily_sales_target = 7000 where id = ?', [$this->fx['branch_a']]);
        \App\Services\AdminActions::bump();
        app()->forgetScopedInstances();
        $page = $this->actingAs($admin)->get('/dashboard')->assertOk()->assertSee('of ₱7,000 target', false);
        $branches = collect($page->viewData('branches'))->keyBy('id');
        $this->assertNull($branches[$this->fx['branch_b']]['daily_target']);
    }

    public function test_heavy_pages_read_everything_in_one_batched_round_trip_against_the_real_functions(): void
    {
        $admin = $this->portalAdmin();
        foreach (['/dashboard', '/s/inventory?branch='.$this->fx['branch_a'], '/s/reports'] as $url) {
            $this->actingAs($admin)->get($url)->assertOk();
            $log = array_column(\App\Support\SupabaseTimer::$log, 'fn');
            $batches = array_values(array_filter($log, fn ($f) => str_starts_with($f, 'batch[')));
            $this->assertCount(1, $batches, "$url: one batched read (".implode(', ', $log).')');
            $this->assertLessThanOrEqual(4, count(array_diff($log, ['connect'])), "$url: ".implode(', ', $log));
        }
        // The batch is an optimisation only: the numbers equal the single calls.
        $repo = app(\App\Services\Supabase\SupabaseRepository::class);
        $single = $repo->inventory($this->fx['branch_a']);
        app()->forgetScopedInstances();
        $repo = app(\App\Services\Supabase\SupabaseRepository::class);
        $repo->prefetch([['inventory', [$this->fx['branch_a']]], ['expiringBatches', [$this->fx['branch_a'], 30]]]);
        $this->assertEquals($single, $repo->inventory($this->fx['branch_a']));
    }

    // ---- shared data: what the app does shows up in the portal ---------------------------

    public function test_dashboard_and_payments_show_the_apps_real_orders(): void
    {
        $order = $this->placeOrder('a');
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->get('/dashboard')->assertOk()
            ->assertSee($this->fx['branch_a_name'])->assertSee($this->fx['branch_b_name'])->assertDontSee('Test data');

        $this->actingAs($admin)->get('/admin/payments?status=pending')->assertOk()->assertSee($order)->assertSee('Mark as paid');
    }

    public function test_the_live_pulse_runs_as_the_staff_member_and_sees_app_changes(): void
    {
        $admin = $this->portalAdmin();
        $staff = $this->portalStaff();
        foreach ([$admin, $staff] as $u) {   // owner and branch staff: RLS lets both read it
            $this->actingAs($u)->getJson('/ui/pulse.json')->assertOk()->assertJson(['changed' => false]);
        }
        $this->assertTrue(\Illuminate\Support\Facades\Cache::get('melai:pulse-off:'.\App\Support\Swr::scope()) === null);

        $this->placeOrder('a');   // a customer orders in the app
        $this->actingAs($admin)->getJson('/ui/pulse.json')->assertJson(['changed' => true]);
        $this->actingAs($admin)->getJson('/ui/pulse.json')->assertJson(['changed' => false]);
        $this->actingAs($staff)->getJson('/ui/pulse.json')->assertJson(['changed' => true]);
    }

    public function test_marking_cash_paid_writes_to_the_apps_database_once(): void
    {
        $order = $this->placeOrder('a');
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->post(route('admin.payments.mark-paid', $order))->assertSessionHas('status');
        $this->assertSame('success', $this->db()->selectOne('select status from public.payments where order_id = ?', [$order])->status);
        $this->assertTrue((bool) $this->db()->selectOne("select exists (select 1 from public.notifications where firebase_uid = ? and category = 'payment') as e", [$this->fx['customer']])->e);

        // Second click: refused, nothing changes.
        $this->actingAs($admin)->post(route('admin.payments.mark-paid', $order))->assertSessionHasErrors('order');
        $this->assertSame(1, (int) $this->db()->selectOne('select count(*) as n from public.payments where order_id = ?', [$order])->n);
    }

    public function test_cash_refund_is_completed_in_the_app_with_stock_and_points_handled_by_the_database(): void
    {
        $order = $this->placeOrder('a');
        $this->completeOrder($order);
        $pointsBefore = (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance;
        $this->assertSame(4, $pointsBefore, 'PHP 200 at 1 point per PHP 50');
        $refund = $this->requestRefund($order);
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->get('/admin/refunds')->assertOk()->assertSee($order)->assertSee($refund);
        $this->actingAs($admin)->post(route('admin.refunds.approve', $order), ['amount' => 1])->assertSessionHasErrors('amount');
        $this->actingAs($admin)->post(route('admin.refunds.approve', $order))->assertSessionHas('status');

        $row = $this->db()->selectOne('select r.status as refund, o.status as ord, p.status as pay from public.refund_requests r
            join public.orders o on o.id = r.order_id join public.payments p on p.order_id = o.id where r.id = ?', [$refund]);
        $this->assertSame(['completed', 'refunded', 'refunded'], [$row->refund, $row->ord, $row->pay]);
        $this->assertSame(0, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance);
        $this->assertSame(1, (int) $this->db()->selectOne("select count(*) as n from public.staff_audit_logs where entity_id = ? and action = 'refund.approve_cash'", [$refund])->n);
        $this->assertTrue(ActivityLog::where('action', 'refund.approved_cash')->exists());

        // Approving again is refused by the portal and, underneath, by the database.
        $this->actingAs($admin)->post(route('admin.refunds.approve', $order))->assertSessionHasErrors('refund');
    }

    public function test_online_refund_is_approved_then_completed_with_a_hitpay_reference(): void
    {
        $order = $this->placeOrder('b', 'GCash E-Wallet');
        $this->completeOrder($order, 'GCASH-REF-'.$this->sfx);
        $refund = $this->requestRefund($order, 1);
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->post(route('admin.refunds.approve', $order))->assertSessionHas('status');
        $this->assertSame('approved', $this->db()->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $this->actingAs($admin)->get('/admin/refunds')->assertSee('Mark refunded');

        $this->actingAs($admin)->post(route('admin.refunds.complete', $order), ['reference' => ''])->assertSessionHasErrors('reference');
        $this->actingAs($admin)->post(route('admin.refunds.complete', $order), ['reference' => 'HP-RF-12345'])->assertSessionHas('status');
        $this->assertSame('completed', $this->db()->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $this->assertSame('100.00', $this->db()->selectOne('select amount from public.refund_requests where id = ?', [$refund])->amount, 'partial refund of 1 of 2 packs');
    }

    public function test_rejecting_a_refund_tells_the_customer_why(): void
    {
        $order = $this->placeOrder('a');
        $this->completeOrder($order);
        $refund = $this->requestRefund($order);
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->post(route('admin.refunds.reject', $order), ['reason' => 'Seal was broken by customer'])->assertSessionHas('status');
        $this->assertSame('rejected', $this->db()->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $this->assertTrue((bool) $this->db()->selectOne("select exists (select 1 from public.notifications where firebase_uid = ? and body like '%Seal was broken%') as e", [$this->fx['customer']])->e);
    }

    // ---- loyalty -------------------------------------------------------------------------

    public function test_loyalty_adjustment_is_applied_once_and_visible_to_the_customer(): void
    {
        $admin = $this->portalAdmin();
        $this->db()->insert('insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values (?, 5, 5)', [$this->fx['customer']]);

        $this->actingAs($admin)->get('/loyalty?q='.urlencode("CARD-{$this->sfx}"))->assertOk()->assertSee("IT Customer {$this->sfx}");
        $key = Str::random(32);
        $url = route('admin.loyalty.adjust', $this->fx['customer']);

        $this->actingAs($admin)->post($url, ['points' => -6, 'reason' => 'Correction', 'request_key' => $key])->assertSessionHas('error');
        $this->actingAs($admin)->post($url, ['points' => 20, 'reason' => 'Birthday bonus', 'request_key' => $key])->assertSessionHas('status', fn ($v) => str_contains($v, 'saved for'));
        $this->actingAs($admin)->post($url, ['points' => 20, 'reason' => 'Birthday bonus', 'request_key' => $key])->assertSessionHas('status', 'That adjustment was already saved.');

        $this->assertSame(25, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance);
        $this->assertSame('1', (string) $this->asAppUser($this->fx['customer'], "select count(*)::text from public.loyalty_transactions where source = 'admin_adjust'"));
        $this->actingAs($admin)->get(route('loyalty.show', $this->fx['customer']))->assertOk()->assertSee('Birthday bonus')->assertSee('Manual adjustment');
    }

    public function test_loyalty_settings_change_the_points_of_the_next_app_order(): void
    {
        $admin = $this->portalAdmin();
        $this->actingAs($admin)->put(route('admin.loyalty.settings.update'), ['earn_pesos_per_point' => 0, 'points_per_peso' => 1, 'max_discount_percent' => 50])
            ->assertSessionHasErrors('earn_pesos_per_point');
        $this->actingAs($admin)->put(route('admin.loyalty.settings.update'), ['earn_pesos_per_point' => 20, 'points_per_peso' => 1, 'max_discount_percent' => 50])
            ->assertSessionHas('status');

        $order = $this->placeOrder('a'); // PHP 200
        $this->assertSame(10, (int) $this->db()->selectOne('select points_earned from public.orders where id = ?', [$order])->points_earned);

        $this->db()->update("update public.loyalty_cart_settings set earn_pesos_per_point = 50 where id = 'default'"); // leave the shared test DB as found
    }

    public function test_profit_and_stock_value_page_reads_the_real_owner_reports(): void
    {
        $admin = $this->portalAdmin();
        $page = $this->actingAs($admin)->get('/admin/profit')->assertOk()->assertSee('Profit by product option');
        $this->assertNull($page->viewData('loadError'));
        $this->assertArrayHasKey('totals', $page->viewData('profit'));
        $this->assertArrayHasKey('totals', $page->viewData('valuation'));
        $this->actingAs($admin)->get('/admin/profit/export/valuation')->assertOk();
    }

    public function test_business_settings_and_branch_details_are_saved_in_the_app_database_by_the_owner_only(): void
    {
        $db = $this->db();
        $before = $db->selectOne("select to_jsonb(s) as j from public.business_settings s where id = 'default'")?->j;
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->get('/admin/business-settings')->assertOk()->assertSee($this->fx['branch_a_name']);
        $this->actingAs($admin)->put('/admin/business-settings', ['restock_threshold_default' => '9', 'healthy_margin_percent' => '30',
            'sales_low_percent' => '60', 'sales_high_percent' => '120'])->assertRedirect(route('admin.business.index'))->assertSessionHas('status');
        $row = $db->selectOne("select restock_threshold_default, healthy_margin_percent, sales_low_ratio, sales_high_ratio, stock_low_ratio, carried_over
                               from public.business_settings where id = 'default'");
        $this->assertSame([9, 30.0, 0.6, 1.2, null, false], [(int) $row->restock_threshold_default, (float) $row->healthy_margin_percent,
            (float) $row->sales_low_ratio, (float) $row->sales_high_ratio, $row->stock_low_ratio, (bool) $row->carried_over]);
        $this->assertSame(9, (int) $db->selectOne('select public._default_restock_threshold() as t')->t, 'the database uses it right away');

        $this->actingAs($admin)->put('/admin/branches/'.$this->fx['branch_a'], ['name' => $this->fx['branch_a_name'], 'address' => 'Real street 1',
            'contact_phone' => '09170000000', 'operating_hours' => '8 AM - 6 PM', 'delivery_fee' => '25', 'daily_sales_target' => '3000',
            'supports_delivery' => '1', 'supports_pickup' => '1', 'is_active' => '1'])->assertRedirect()->assertSessionHas('status');
        $b = $db->selectOne('select address, contact_phone, operating_hours, delivery_fee, daily_sales_target from public.branches where id = ?', [$this->fx['branch_a']]);
        $this->assertSame(['Real street 1', '09170000000', '8 AM - 6 PM', 25.0, 3000.0],
            [$b->address, $b->contact_phone, $b->operating_hours, (float) $b->delivery_fee, (float) $b->daily_sales_target]);

        // Staff are refused by the website AND by the database.
        $this->actingAs($this->portalStaff())->put('/admin/business-settings', ['restock_threshold_default' => '1'])->assertForbidden();
        $this->expectException(\Illuminate\Database\QueryException::class);
        try {
            $this->asAppUser($this->fx['staff_a'], "select public.owner_update_business_settings('{\"restock_threshold_default\": 1}'::jsonb)");
        } finally {
            $this->assertSame(9, (int) $db->selectOne("select restock_threshold_default from public.business_settings where id = 'default'")->restock_threshold_default);
            // leave the shared test database as found
            $db->update('update public.branches set daily_sales_target = null where id = ?', [$this->fx['branch_a']]);
            $db->delete("delete from public.business_settings where id = 'default'");
            if ($before) {
                $db->insert('insert into public.business_settings select * from jsonb_populate_record(null::public.business_settings, ?::jsonb)', [$before]);
            }
        }
    }

    // ---- races: the same action sent at the same moment from several sessions -------------

    /**
     * Runs $n copies of $sql at the same instant, each in its OWN database session acting as the
     * app account $uid (exactly how the website's gateway calls a function: claims + role
     * `authenticated`, one transaction). Returns one "ok:<json>" or "err:<message>" per copy.
     */
    private function race(int $n, string $uid, string $sql, array $bindings): array
    {
        if (! function_exists('pcntl_fork')) {
            $this->markTestSkipped('needs the pcntl extension');
        }
        $u = parse_url(env('SUPABASE_TEST_PORTAL_URL'));
        $dsn = sprintf('pgsql:host=%s;port=%d;dbname=%s', $u['host'], $u['port'] ?? 5432, ltrim($u['path'], '/'));
        $claims = json_encode(['sub' => $uid, 'role' => 'authenticated']);
        $dir = sys_get_temp_dir().'/melai-race-'.Str::random(8);
        mkdir($dir);
        $start = microtime(true) + 0.6;
        $pids = [];
        for ($i = 0; $i < $n; $i++) {
            $pid = pcntl_fork();
            if ($pid === 0) {
                $out = 'err:not run';
                try {
                    $pdo = new \PDO($dsn, urldecode($u['user']), urldecode($u['pass'] ?? ''), [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
                    while (microtime(true) < $start) {
                        usleep(500);
                    }
                    $pdo->beginTransaction();
                    $pdo->prepare("select set_config('request.jwt.claims', ?, true), set_config('role', 'authenticated', true)")->execute([$claims]);
                    $st = $pdo->prepare($sql);
                    $st->execute(array_map(fn ($b) => is_callable($b) ? $b($i) : $b, $bindings));
                    $out = 'ok:'.$st->fetchColumn();
                    $pdo->commit();
                } catch (\Throwable $e) {
                    $out = 'err:'.preg_replace('/^SQLSTATE\[\w+\]: [^:]+: \d+ ERROR:\s*/', '', strtok($e->getMessage(), "\n"));
                }
                file_put_contents("$dir/$i", $out);
                exit(0); // child: no PHPUnit / Laravel shutdown
            }
            $pids[] = $pid;
        }
        foreach ($pids as $pid) {
            pcntl_waitpid($pid, $status);
        }
        $results = array_map(fn ($i) => (string) @file_get_contents("$dir/$i"), range(0, $n - 1));
        array_map('unlink', glob("$dir/*"));
        rmdir($dir);
        DB::purge('supabase');
        DB::purge('supabase_admin');

        return $results;
    }

    public function test_a_double_submitted_loyalty_adjustment_racing_in_parallel_is_applied_once(): void
    {
        $this->db()->insert('insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values (?, 5, 5)', [$this->fx['customer']]);
        $key = 'race-'.Str::random(20);

        $results = $this->race(8, $this->fx['owner'],
            'select public.owner_adjust_loyalty_points(?::text, ?::int, ?::text, ?::text)::text',
            [$this->fx['customer'], 20, 'Race test', $key]);

        $applied = array_filter($results, fn ($r) => str_starts_with($r, 'ok:') && ! str_contains($r, '"duplicate": true') && ! str_contains($r, '"duplicate":true'));
        $this->assertCount(1, $applied, 'exactly one of 8 simultaneous submits applies: '.implode(' | ', $results));
        $this->assertSame([], array_values(array_filter($results, fn ($r) => str_starts_with($r, 'err:'))), 'the others answer "duplicate", not an error');
        $this->assertSame(25, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance);
        $this->assertSame(1, (int) $this->db()->selectOne("select count(*) as n from public.loyalty_transactions where firebase_uid = ? and source = 'admin_adjust'", [$this->fx['customer']])->n);
    }

    public function test_parallel_deductions_with_different_keys_never_make_a_balance_negative(): void
    {
        $this->db()->insert('insert into public.loyalty_accounts (firebase_uid, points_balance, lifetime_points) values (?, 30, 30)', [$this->fx['customer']]);
        $prefix = 'deduct-'.Str::random(12).'-';

        $results = $this->race(6, $this->fx['owner'],
            'select public.owner_adjust_loyalty_points(?::text, ?::int, ?::text, ?::text)::text',
            [$this->fx['customer'], -10, 'Race deduction', fn ($i) => $prefix.$i]);

        $ok = count(array_filter($results, fn ($r) => str_starts_with($r, 'ok:')));
        $this->assertSame(3, $ok, '30 points cover exactly three deductions of 10: '.implode(' | ', $results));
        $this->assertSame(0, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance);
        foreach (array_filter($results, fn ($r) => str_starts_with($r, 'err:')) as $r) {
            $this->assertStringContainsString('cannot deduct more points', $r);
        }
    }

    public function test_a_refund_approved_from_several_sessions_at_once_is_completed_once(): void
    {
        $order = $this->placeOrder('a');
        $this->completeOrder($order);
        $refund = $this->requestRefund($order);
        $paidBefore = (float) $this->db()->selectOne('select amount from public.payments where order_id = ?', [$order])->amount;

        $results = $this->race(6, $this->fx['owner'],
            'select public.admin_portal_review_refund(?::text, ?::text, ?::text)::text',
            [$refund, 'approve_cash', null]);

        $this->assertCount(1, array_filter($results, fn ($r) => str_starts_with($r, 'ok:')), 'one approval wins: '.implode(' | ', $results));
        $row = $this->db()->selectOne('select r.status as refund, o.status as ord, p.status as pay, p.amount from public.refund_requests r
            join public.orders o on o.id = r.order_id join public.payments p on p.order_id = o.id where r.id = ?', [$refund]);
        $this->assertSame(['completed', 'refunded', 'refunded'], [$row->refund, $row->ord, $row->pay]);
        $this->assertSame($paidBefore, (float) $row->amount, 'the payment record is not changed twice');
        $this->assertSame(1, (int) $this->db()->selectOne("select count(*) as n from public.staff_audit_logs where entity_id = ? and action = 'refund.approve_cash'", [$refund])->n);
        $this->assertSame(0, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance,
            'earned points reversed once, never below zero');
        $this->assertSame(1, (int) $this->db()->selectOne("select count(*) as n from public.loyalty_transactions where order_id = ? and source = 'order_clawback'", [$order])->n);
    }

    // ---- branch scoping, catalog, inventory ------------------------------------------------

    public function test_branch_staff_only_see_their_branch(): void
    {
        $orderA = $this->placeOrder('a');
        $orderB = $this->placeOrder('b');
        $staff = $this->portalStaff();

        $this->actingAs($staff)->get('/dashboard')->assertOk()->assertSee($this->fx['branch_a_name'])->assertDontSee($this->fx['branch_b_name']);
        $this->actingAs($staff)->get('/s/inventory?branch='.$this->fx['branch_b'])->assertOk()
            ->assertSee($this->fx['branch_a_name'])->assertDontSee($this->fx['branch_b_name']);
        $this->actingAs($staff)->get('/s/sales')->assertOk()->assertSee('your branch only');
        // Admin-only pages stay admin-only for portal staff.
        $this->actingAs($staff)->get('/admin/payments')->assertForbidden();

        $owner = $this->portalAdmin();
        $this->actingAs($owner)->get('/admin/payments')->assertSee($orderA)->assertSee($orderB);
    }

    public function test_hiding_a_product_hides_it_from_app_customers(): void
    {
        $admin = $this->portalAdmin();
        $this->actingAs($admin)->get('/s/products')->assertOk()->assertSee("IT-{$this->sfx} Garlic Peanuts");

        $this->actingAs($admin)->post(route('ops.products.toggle', $this->fx['product']), ['active' => 0])->assertSessionHas('status');
        $visibleToCustomer = $this->asAppUser($this->fx['customer'], 'select count(*) from public.products where id = ?', [$this->fx['product']]);
        $this->assertSame(0, (int) $visibleToCustomer);

        $this->actingAs($admin)->post(route('ops.products.toggle', $this->fx['product']), ['active' => 1])->assertSessionHas('status');
        $this->assertSame(1, (int) $this->asAppUser($this->fx['customer'], 'select count(*) from public.products where id = ?', [$this->fx['product']]));
    }

    public function test_inventory_reflects_app_sales_and_audit_log_shows_app_actions(): void
    {
        $this->placeOrder('a', 'Cash on Counter Pickup', 3); // checkout deducts stock: 50 -> 47
        $admin = $this->portalAdmin();

        $this->actingAs($admin)->get('/s/inventory?branch='.$this->fx['branch_a'])->assertOk()->assertSee('<strong>47</strong>', false);

        $this->actingAs($admin)->post(route('ops.products.toggle', $this->fx['product']), ['active' => 0]);
        $this->actingAs($admin)->get('/admin/activity-logs')->assertOk()->assertSee('product_active_changed')->assertSee('IT Owner');
        $this->actingAs($admin)->post(route('ops.products.toggle', $this->fx['product']), ['active' => 1]);
    }

    public function test_unreachable_database_shows_a_friendly_error(): void
    {
        config(['database.connections.supabase.url' => 'postgresql://melai_admin_portal:x@127.0.0.1:1/nowhere']);
        DB::purge('supabase');

        $this->actingAs($this->portalAdmin())->get('/s/products')->assertStatus(503)->assertSee('could not be reached');
    }

    // ---- Firebase Authentication: sign-in, registration, approval, tokens -------------------

    public function test_app_owner_signs_in_without_a_website_login_and_gets_a_linked_admin_login(): void
    {
        $email = "owner-{$this->sfx}@test.local";
        $this->post('/login', ['email' => strtoupper($email), 'password' => 'Owner#Pass1'])->assertRedirect(route('dashboard'));

        $u = User::firstWhere('email', $email);
        $this->assertNotNull($u, 'login created from the verified app owner account');
        $this->assertSame('admin', $u->role);
        $this->assertTrue($u->has_access);
        $this->assertSame($this->fx['owner'], $u->firebase_uid);
        $this->assertSame($this->fx['owner'], $u->staff_uid);
        $this->assertSame('IT Owner', $u->name);

        $this->withFirebaseSession = false; // use the session the login stored
        $this->actingAs($u)->get('/dashboard')->assertOk()->assertSee($this->fx['branch_a_name'])->assertSee($this->fx['branch_b_name'])
            ->assertSee('Staff accounts')->assertSee('IT Staff A')->assertDontSee('Account not linked');
    }

    public function test_app_staff_signs_in_and_sees_only_their_branch_even_via_url(): void
    {
        $this->placeOrder('a');
        $orderB = $this->placeOrder('b');
        $email = "staff-a-{$this->sfx}@test.local";
        $this->post('/login', ['email' => $email, 'password' => 'Staff#Pass1'])->assertRedirect();

        $u = User::firstWhere('email', $email);
        $this->assertSame('staff', $u->role);
        $this->assertSame($this->fx['staff_a'], $u->staff_uid);
        $this->withFirebaseSession = false;
        $this->actingAs($u)->get('/dashboard')->assertOk()->assertSee($this->fx['branch_a_name'])->assertDontSee($this->fx['branch_b_name']);
        $this->actingAs($u)->get('/s/inventory?branch='.$this->fx['branch_b'])->assertOk()->assertDontSee($this->fx['branch_b_name']);
        $this->actingAs($u)->get('/s/deliveries?branch='.$this->fx['branch_b'])->assertNotFound(); // no delivery pages on the website
        $this->actingAs($u)->get('/admin/payments?branch='.$this->fx['branch_b'])->assertForbidden();
        $this->actingAs($u)->get('/reports/forecast?branch='.$this->fx['branch_b'])->assertDontSee($orderB);
    }

    public function test_owner_dashboard_shows_every_branch_and_every_staff_account_with_sales_per_cashier(): void
    {
        $this->asAppUser($this->fx['staff_a'], 'select public.staff_open_shift(?::uuid, 500)::text', [$this->fx['branch_a']]);
        $this->asAppUser($this->fx['staff_a'],
            "select public.staff_create_pos_sale(?::uuid, jsonb_build_array(jsonb_build_object('variant_id', ?::text, 'quantity', 3)), 'cash', null, 300)::text",
            [$this->fx['branch_a'], $this->fx['variant']]);
        $admin = $this->portalAdmin();

        $page = $this->actingAs($admin)->get('/dashboard')->assertOk()
            ->assertSee('All branches')->assertSee($this->fx['branch_a_name'])->assertSee($this->fx['branch_b_name'])
            ->assertSee('Top cashiers')->assertSee('IT Staff A')->assertSee('IT Owner');
        $row = collect($page->viewData('staff'))->firstWhere('firebase_uid', $this->fx['staff_a']);
        $this->assertSame(1, $row['pos_transactions']);
        $this->assertEqualsWithDelta(300, (float) $row['pos_sales'], 0.001);
        $this->assertTrue($row['open_shift']);
        $this->assertNotNull($row['last_activity_at']);
        $top = array_map('floatval', array_column($page->viewData('topStaff'), 'pos_net_sales')); // shared test DB: other runs sell too
        $this->assertNotEmpty($top);
        $this->assertSame($top, collect($top)->sortDesc()->values()->all(), 'best cashier first');
        $this->assertSame(2, collect($page->viewData('sales'))->whereIn('id', [$this->fx['branch_a'], $this->fx['branch_b']])->count());

        // Branch filter: only branch B; staff A (branch A, no sales in B) drops out of the staff list.
        $b = $this->actingAs($admin)->get('/dashboard?branch='.$this->fx['branch_b'])->assertOk();
        $this->assertSame([$this->fx['branch_b']], array_column($b->viewData('sales'), 'id'));
        $this->assertNull(collect($b->viewData('staff'))->firstWhere('firebase_uid', $this->fx['staff_a']));

        // Sales page and reports: per-cashier breakdown for the owner, from the same SQL function.
        $this->actingAs($admin)->get('/s/sales?days=7')->assertOk()->assertSee('Sales per cashier')->assertSee('IT Staff A');
        $this->actingAs($admin)->get('/s/reports')->assertOk()->assertSee('Sales by staff');
        $csv = $this->actingAs($admin)->get('/reports/export?section=by_staff')->assertOk()->streamedContent();
        $this->assertStringContainsString('full_name,email,role,branch_name', $csv);
        $this->assertStringContainsString('"IT Staff A"', $csv);
        // Cash drawer: all branches by default for the owner.
        $this->actingAs($admin)->get('/s/cash-drawer')->assertOk()->assertSee('All branches added up')->assertSee('IT Staff A');
    }

    public function test_staff_never_get_the_all_branch_view_or_the_staff_directory(): void
    {
        $this->placeOrder('b');
        $staff = $this->portalStaff();

        $page = $this->actingAs($staff)->get('/dashboard?branch='.$this->fx['branch_b'])->assertOk()
            ->assertDontSee($this->fx['branch_b_name'])->assertDontSee('Staff accounts')->assertDontSee('IT Owner');
        $this->assertNull($page->viewData('staff'));
        $this->assertNull($page->viewData('branchId'), 'a branch the account may not see is ignored');
        $this->assertSame([$this->fx['branch_a']], array_column($page->viewData('sales'), 'id'));

        // The database itself refuses the owner-only function for a staff account.
        $this->expectExceptionMessage('Only an active owner can do this.');
        $this->asAppUser($this->fx['staff_a'], 'select public.owner_staff_overview(now() - interval \'1 day\', now(), null)::text');
    }

    public function test_dashboard_answers_are_cached_briefly_per_account_and_fresh_skips_the_cache(): void
    {
        config(['melai.dashboard.cache_seconds' => 45, 'cache.default' => 'array']);
        $admin = $this->portalAdmin();
        $before = $this->actingAs($admin)->get('/dashboard')->assertOk()->viewData('kpis')['orders'];

        $this->placeOrder('a');
        $this->assertSame($before, $this->actingAs($admin)->get('/dashboard')->viewData('kpis')['orders'], 'served from the 45 s cache');
        $this->assertSame($before + 1, $this->actingAs($admin)->get('/dashboard?fresh=1')->viewData('kpis')['orders']);

        // Another account never sees the owner's cached numbers.
        $staff = $this->portalStaff();
        $this->assertNull($this->actingAs($staff)->get('/dashboard')->assertOk()->viewData('staff'));
    }

    public function test_firebase_account_without_app_profile_is_refused_and_unknown_accounts_get_the_generic_error(): void
    {
        // A customer of the app: real Firebase account, not in the staff registry.
        $this->fb->addAccount("cust-{$this->sfx}@test.local", $this->fx['customer'], 'Cust#Pass1');
        $this->post('/login', ['email' => "cust-{$this->sfx}@test.local", 'password' => 'Cust#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('not registered as staff or owner', session('errors')->first('auth'));
        $this->assertDatabaseMissing('users', ['email' => "cust-{$this->sfx}@test.local"]);
        $this->assertGuest();

        // No Firebase account at all: generic message (Firebase does not reveal which emails exist).
        $this->post('/login', ['email' => "nobody-{$this->sfx}@test.local", 'password' => 'x'])
            ->assertSessionHasErrors(['auth' => 'Invalid email or password. Use your Melai Nuts app email and password.']);
    }

    public function test_login_page_separates_local_password_missing_profile_and_missing_config(): void
    {
        // Website login with a local password only; the email has NO Firebase account.
        $u = User::factory()->create(['email' => "new-{$this->sfx}@test.local", 'role' => 'staff', 'has_access' => true, 'password' => 'Local#Pass1']);
        $this->post('/login', ['email' => $u->email, 'password' => 'Local#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString("No staff account in the app's staff registry (staff_members) has the email {$u->email}", session('errors')->first('auth'));
        $this->assertGuest();

        // Firebase account exists, but no staff registration: refused with that reason (the login IS bound to the account).
        $this->fb->addAccount($u->email, "it-new-{$this->sfx}", 'New#Pass1');
        $this->post('/login', ['email' => $u->email, 'password' => 'New#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('App profile missing', session('errors')->first('auth'));
        $this->assertStringContainsString('staff_members', session('errors')->first('auth'));
        $this->assertGuest();
        $this->assertNull($u->fresh()->staff_uid);
        $this->assertSame("it-new-{$this->sfx}", $u->fresh()->firebase_uid);

        // Configuration missing: reported by name.
        config(['services.firebase.web_api_key' => null]);
        $this->post('/login', ['email' => $u->email, 'password' => 'New#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('FIREBASE_WEB_API_KEY', session('errors')->first('auth'));
    }

    public function test_all_users_page_lists_app_staff_and_customers_from_the_database(): void
    {
        $this->completeOrder($this->placeOrder('a')); // 2 × ₱100, paid
        $this->placeOrder('b');                         // pending: counted as an order, not as paid
        $owner = $this->portalAdmin();

        $page = $this->actingAs($owner)->get('/admin/users?q='.$this->sfx)->assertOk()
            ->assertSee('IT Staff A')->assertSee("IT Customer {$this->sfx}")->assertSee("Card CARD-{$this->sfx}")
            ->assertSee('2 orders · ₱200.00 paid', false);
        $people = collect($page->viewData('people')->items());
        $this->assertSame(['logins', 'team'], $people->firstWhere('email', "owner-{$this->sfx}@test.local")['types'], 'owner login merged with its staff row');
        $this->assertSame(['customers'], $people->firstWhere('name', "IT Customer {$this->sfx}")['types']);
        $this->assertFalse($page->viewData('partial'));

        // A staff login gets no all-users data: the page is admin-only and the function owner-only.
        $this->assertNotNull($this->asAppUser($this->fx['owner'], 'select public.owner_all_users(null, 5)::text'));
        $this->expectException(\Illuminate\Database\QueryException::class);
        $this->asAppUser($this->fx['staff_a'], 'select public.owner_all_users(null, 5)::text');
    }

    public function test_website_registration_is_approved_by_the_owner_and_registered_in_the_app(): void
    {
        $email = "reg-{$this->sfx}@test.local";
        $this->post('/register', ['name' => 'Rhea Reg', 'email' => $email, 'password' => 'Kasoy#Tanim12', 'password_confirmation' => 'Kasoy#Tanim12', 'terms' => '1'])
            ->assertRedirect(route('waiting'));
        $reg = User::firstWhere('email', $email);
        $uid = $reg->firebase_uid;
        $this->assertNotNull($this->fb->account($uid));
        $this->post('/logout');

        $owner = $this->portalAdmin();
        // Not approvable before the email is verified.
        $this->actingAs($owner)->from('/admin/users')->post(route('admin.users.approve', $reg), ['role' => 'staff', 'branch_id' => $this->fx['branch_b']])
            ->assertSessionHasErrors('approve');
        $this->assertNull($this->db()->selectOne('select 1 from public.staff_members where firebase_uid = ?', [$uid]));

        // Registrant verifies the email and checks the waiting page once.
        $this->fb->set($uid, 'verified', true);
        $this->actingAs($reg)->get('/waiting')->assertOk()->assertSee('Email verified');
        $this->assertTrue($reg->fresh()->firebase_email_verified);

        $this->actingAs($owner)->get('/admin/users')->assertOk()->assertSee('Approve');
        $this->actingAs($owner)->from('/admin/users')->post(route('admin.users.approve', $reg), ['role' => 'staff', 'branch_id' => $this->fx['branch_b']])
            ->assertSessionHasNoErrors()->assertSessionHas('status');

        $row = $this->db()->selectOne('select role, branch_id, email, account_status from public.staff_members where firebase_uid = ?', [$uid]);
        $this->assertSame(['staff', $this->fx['branch_b'], $email, 'active'], [$row->role, $row->branch_id, $row->email, $row->account_status]);
        $this->assertSame(['role' => 'staff', 'branch' => $this->fx['branch_b_name']], array_intersect_key($this->fb->profiles[$uid], ['role' => 1, 'branch' => 1]));
        $reg = $reg->fresh();
        $this->assertSame($uid, $reg->staff_uid);
        $this->assertTrue($reg->has_access);
        $this->assertTrue(ActivityLog::where('action', 'account.provisioned')->exists());

        // The new staff member works in branch B only.
        $this->actingAs($reg)->get('/dashboard')->assertOk()->assertSee($this->fx['branch_b_name'])->assertDontSee($this->fx['branch_a_name']);
    }

    public function test_failed_firestore_write_rolls_back_the_staff_registration(): void
    {
        $reg = User::factory()->create(['email' => "rb-{$this->sfx}@test.local", 'role' => 'staff', 'has_access' => false]);
        $reg->forceFill(['firebase_uid' => "it-rb-{$this->sfx}", 'firebase_email_verified' => true])->save();
        $this->fb->addAccount($reg->email, "it-rb-{$this->sfx}", 'Rb#Pass123', true);
        $this->fb->firestoreDenied = true;

        $owner = $this->portalAdmin();
        $this->actingAs($owner)->from('/admin/users')->post(route('admin.users.approve', $reg), ['role' => 'staff', 'branch_id' => $this->fx['branch_a']])
            ->assertSessionHasErrors('approve');
        $this->assertStringContainsString('Nothing was registered', session('errors')->first('approve'));
        $this->assertNull($this->db()->selectOne('select 1 from public.staff_members where firebase_uid = ?', ["it-rb-{$this->sfx}"]), 'staff row rolled back');
        $this->assertNull($reg->fresh()->staff_uid);
        $this->assertFalse($reg->fresh()->has_access);
    }

    public function test_nobody_can_make_themselves_owner(): void
    {
        // Registration ignores any role field.
        $email = "self-{$this->sfx}@test.local";
        $this->post('/register', ['name' => 'Self', 'email' => $email, 'password' => 'Kasoy#Tanim12', 'password_confirmation' => 'Kasoy#Tanim12', 'terms' => '1', 'role' => 'admin']);
        $self = User::firstWhere('email', $email);
        $this->assertSame('staff', $self->role);
        $this->fb->set($self->firebase_uid, 'verified', true);

        // A pending or staff login cannot reach the approval endpoint (server-side role check).
        $this->post(route('admin.users.approve', $self), ['role' => 'owner'])->assertForbidden();
        $staff = $this->portalStaff();
        $this->actingAs($staff)->post(route('admin.users.approve', $self), ['role' => 'owner'])->assertForbidden();
        $this->actingAs($staff)->post(route('admin.users.approve', $staff), ['role' => 'owner'])->assertForbidden();
        $this->assertSame('staff', $staff->fresh()->role);
        $this->assertNull($this->db()->selectOne("select 1 from public.staff_members where firebase_uid = ? ", [$self->firebase_uid]));

        // Even if the website's own role column were changed to admin, the app account behind it is staff:
        // the database (owner-only SQL function) refuses, so no owner can be created.
        $fakeAdmin = $staff->fresh();
        $fakeAdmin->forceFill(['role' => 'admin'])->save();
        $this->actingAs($fakeAdmin)->from('/admin/users')->post(route('admin.users.approve', $self), ['role' => 'owner'])->assertSessionHasErrors('approve');
        $this->assertNull($this->db()->selectOne('select 1 from public.staff_members where firebase_uid = ?', [$self->firebase_uid]));
    }

    public function test_admin_creates_an_app_staff_account_that_can_sign_in(): void
    {
        $owner = $this->portalAdmin();
        $email = "made-{$this->sfx}@test.local";
        $this->actingAs($owner)->post(route('admin.users.store'), ['name' => 'Made Staff', 'email' => $email, 'role' => 'staff',
            'branch_id' => $this->fx['branch_a'], 'password' => 'Kasoy#Tanim12', 'password_confirmation' => 'Kasoy#Tanim12'])
            ->assertRedirect(route('admin.users.index'));

        // The owner who created it stays signed in (same browser session).
        $this->get(route('admin.users.index'))->assertOk()->assertSee($email);
        $this->assertAuthenticatedAs($owner);

        $u = User::firstWhere('email', $email);
        $this->assertNotNull($this->fb->account($u->firebase_uid), 'Firebase account created');
        $this->assertSame($u->firebase_uid, $u->staff_uid);
        $this->assertSame('staff', $this->db()->selectOne('select role from public.staff_members where firebase_uid = ?', [$u->firebase_uid])->role);
        $this->assertSame('staff', $this->fb->profiles[$u->firebase_uid]['role']);
        $this->post('/logout');

        $this->post('/login', ['email' => $email, 'password' => 'Kasoy#Tanim12'])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($u->fresh());

        // Same email again: refused, nothing duplicated.
        $this->actingAs($owner)->from('/admin/users/create')->post(route('admin.users.store'), ['name' => 'Again', 'email' => $email, 'role' => 'staff',
            'branch_id' => $this->fx['branch_a'], 'password' => 'Kasoy#Tanim12', 'password_confirmation' => 'Kasoy#Tanim12'])->assertSessionHasErrors('email');
        $this->assertSame(1, User::where('email', $email)->count());
    }

    public function test_owner_signed_in_with_the_website_password_confirms_with_the_app_password_and_stays_signed_in(): void
    {
        // Website-password login of the owner: linked to the owner row, no app (Firebase) sign-in in the session.
        $owner = User::factory()->create(['email' => "owner-{$this->sfx}@test.local", 'role' => 'admin', 'has_access' => true]);
        $owner->forceFill(['staff_uid' => $this->fx['owner']])->save();
        $email = "local-made-{$this->sfx}@test.local";
        $form = ['name' => 'Local Made', 'email' => $email, 'role' => 'staff', 'branch_id' => $this->fx['branch_a'],
            'password' => 'Kasoy#Tanim12', 'password_confirmation' => 'Kasoy#Tanim12'];

        $this->actingAs($owner)->get(route('admin.users.create'))->assertOk()->assertSee('Your Melai Nuts app password');

        // No app password / a wrong one: a form error, nothing created, and the owner is NOT signed out.
        $this->actingAs($owner)->from(route('admin.users.create'))->post(route('admin.users.store'), $form)
            ->assertRedirect(route('admin.users.create'))->assertSessionHasErrors('owner_password');
        $this->actingAs($owner)->from(route('admin.users.create'))->post(route('admin.users.store'), $form + ['owner_password' => 'nope'])
            ->assertSessionHasErrors('owner_password')->assertSessionMissing('_old_input.owner_password');
        $this->assertAuthenticatedAs($owner);
        $this->assertNull(User::firstWhere('email', $email));
        $this->assertNull($this->fb->accounts[$email] ?? null, 'no Firebase account was created');

        // With the app password: created, and the owner keeps working.
        $this->actingAs($owner)->post(route('admin.users.store'), $form + ['owner_password' => 'Owner#Pass1'])
            ->assertRedirect(route('admin.users.index'))->assertSessionHasNoErrors();
        $this->get(route('admin.users.index'))->assertOk()->assertSee($email);
        $this->assertAuthenticatedAs($owner);
        $u = User::firstWhere('email', $email);
        $this->assertSame('staff', $this->db()->selectOne('select role from public.staff_members where firebase_uid = ?', [$u->firebase_uid])->role);
        $this->assertSame('staff', $this->fb->profiles[$u->firebase_uid]['role']);
    }

    public function test_expired_token_is_refreshed_and_revoked_disabled_or_forged_tokens_are_rejected(): void
    {
        $owner = $this->portalAdmin();
        $this->withFirebaseSession = false;

        // Expired ID token, valid refresh token: refreshed transparently.
        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, expiresIn: 30))->get('/dashboard')->assertOk();

        // Sessions revoked in Firebase (password changed / deactivate-user.js): refresh fails -> sign in again.
        $this->fb->set($this->fx['owner'], 'revoked', true);

        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, expiresIn: 30))->get('/dashboard')
            ->assertRedirect(route('login'))->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->assertStringContainsString('sign in again', strtolower(session('errors')->first('auth')));
        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, expiresIn: 30))->getJson('/dashboard/overview.json')->assertStatus(401);
        $this->fb->set($this->fx['owner'], 'revoked', false);

        // Account disabled in Firebase.
        $this->fb->set($this->fx['owner'], 'disabled', true);
        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, expiresIn: 30))->get('/s/products')->assertRedirect(route('login'));
        $this->fb->set($this->fx['owner'], 'disabled', false);

        // Forged token (signed with another key) and a token of another account: rejected, nothing read.
        $pem = FakeFirebase::otherPrivateKeyPem();
        $forged = $this->fb->token($this->fx['owner'], $owner->email, false, [], $pem);
        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, idToken: $forged))->getJson('/dashboard/overview.json')->assertStatus(401);
        $other = $this->fb->token($this->fx['staff_a'], $owner->email);
        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, idToken: $other))->get('/dashboard')->assertRedirect(route('login'));

        // A website-password session (no Firebase sign-in in it) acts as the server-side link,
        // and the account's status is still checked with Supabase on every request.
        $this->actingAs($owner)->withSession(['firebase_auth' => null])->get('/admin/payments')->assertOk();
    }

    public function test_seeded_local_admin_is_bound_and_linked_when_the_owner_signs_in(): void
    {
        $admin = User::factory()->create(['email' => "owner-{$this->sfx}@test.local", 'role' => 'admin', 'has_access' => true, 'password' => 'Seed#Pass1']);
        $this->post('/login', ['email' => $admin->email, 'password' => 'Owner#Pass1'])->assertRedirect(route('dashboard'));
        $admin = $admin->fresh();
        $this->assertSame($this->fx['owner'], $admin->firebase_uid);
        $this->assertSame($this->fx['owner'], $admin->staff_uid);
        $this->assertSame(1, User::where('email', $admin->email)->count(), 'no duplicate login');
        $this->post('/logout');
        $this->post('/login', ['email' => $admin->email, 'password' => 'Seed#Pass1'])->assertSessionHasErrors('auth');
    }

    // ---- reports, forecast, cash drawer (migrations 20261010*) ----------------------------

    /** Writes $days days of verified in-store history (units = 10 + day/2) straight into the tables. */
    private function seedHistory(string $branch, int $days): void
    {
        $db = $this->db();
        for ($d = 1; $d <= $days; $d++) {
            $units = 10 + intdiv($d, 2);
            $at = now('Asia/Manila')->startOfDay()->subDays($days + 1 - $d)->addHours(10)->toIso8601String();
            $db->transaction(function ($db) use ($branch, $units, $at) {   // the order integrity check runs at commit
            $id = $db->selectOne("insert into public.orders (firebase_uid, branch_id, branch_name, is_delivery, status, subtotal, discount, delivery_fee, total, payment_method, created_at)
                                  values ('walk-in', ?, ?, false, 'completed', ?, 0, 0, ?, 'Cash (In-store)', ?) returning id",
                [$this->fx["branch_$branch"], $this->fx["branch_{$branch}_name"], $units * 100, $units * 100, $at])->id;
            $db->insert("insert into public.order_items (order_id, product_id, variant_id, product_name, variant_label, quantity, unit_price)
                         values (?, ?, ?, ?, 'Regular', ?, 100)", [$id, $this->fx['product'], $this->fx['variant'], "IT-{$this->sfx} Garlic Peanuts", $units]);
            $db->insert("insert into public.payments (order_id, firebase_uid, method, status, amount, reference_number, created_at)
                         values (?, 'walk-in', 'cash', 'success', ?, ?, ?)", [$id, $units * 100, $id, $at]);
            });
        }
    }

    public function test_reports_use_verified_sales_and_export_csv(): void
    {
        $paid = $this->placeOrder('a', 'Cash on Counter Pickup', 2);   // P200, completed below
        $this->completeOrder($paid);
        $this->placeOrder('a', 'Cash on Counter Pickup', 3);           // P300, payment still pending
        $admin = $this->portalAdmin();
        $q = '?branch='.$this->fx['branch_a'];

        $this->actingAs($admin)->get('/s/reports'.$q)->assertOk()
            ->assertSee('Gross sales')->assertSee('₱200.00')            // only the verified order
            ->assertSee('Pending payments (not counted)')->assertSee('₱300.00')
            ->assertSee('How these numbers are calculated');

        $csv = $this->actingAs($admin)->get('/reports/export'.$q.'&section=by_branch');
        $csv->assertOk()->assertHeader('content-type', 'text/csv; charset=UTF-8');
        $body = $csv->streamedContent();
        $this->assertStringContainsString('branch,orders,gross_sales,discounts,refunds,refund_count,net_sales,refund_rate,pending_refund_count,pending_refund_amount', $body);
        $this->assertStringContainsString('"'.$this->fx['branch_a_name'].'",1,200', $body);
        $this->assertTrue(ActivityLog::where('action', 'report.exported')->exists());

        $this->actingAs($admin)->get('/reports/export'.$q.'&section=../../etc')->assertNotFound();
    }

    /**
     * One partial refund, followed through every figure: the website (dashboard, sales page, reports +
     * CSV, orders, payments, refunds) and the app's own functions (owner_sales_summary,
     * staff_get_dashboard, analytics_report, the customer's get_my_order_refunds) show the same
     * numbers, a pending refund is not deducted, and the change shows at once (cache bumped).
     */
    public function test_a_partial_refund_flows_into_every_figure_identically_on_the_website_and_in_the_app(): void
    {
        $order = $this->placeOrder('a', 'Cash on Counter Pickup', 2);     // P200
        $this->completeOrder($order);
        $admin = $this->portalAdmin();
        $a = $this->fx['branch_a'];
        $today = now('Asia/Manila')->toDateString();
        $ov = fn () => json_decode($this->asAppUser($this->fx['owner'], 'select public.sales_overview(?::date, ?::date, ?::uuid)::text', [$today, $today, $a]), true);
        $dash = fn () => $this->actingAs($admin)->get('/dashboard?branch='.$a)->assertOk()->viewData('kpis');

        $before = $ov();
        $refund = $this->requestRefund($order, 1);                          // 1 of 2 packs: P100, pending
        $pending = $dash();
        $this->assertEqualsWithDelta((float) $before['summary']['net_sales'], $pending['net_sales'], 0.001, 'a pending refund is not deducted');
        $this->assertEqualsWithDelta((float) $before['pending_refunds']['amount'] + 100, $pending['pending_refund_amount'], 0.001);
        $this->actingAs($admin)->get('/admin/refunds')->assertOk()->assertSee('(partial)')->assertSee('Left to refund on this order');

        $this->actingAs($admin)->post(route('admin.refunds.approve', $order))->assertSessionHas('status'); // cash: completed now
        $after = $ov();
        $k = $dash(); // no ?fresh=1: the refund action bumped the cache version
        $this->assertEqualsWithDelta((float) $before['summary']['net_sales'] - 100, (float) $after['summary']['net_sales'], 0.001);
        $this->assertEqualsWithDelta((float) $before['summary']['gross_sales'], (float) $after['summary']['gross_sales'], 0.001, 'the sale stays in gross');
        $this->assertSame((int) $before['summary']['refund_count'] + 1, (int) $after['summary']['refund_count']);
        foreach (['gross_sales', 'refunds', 'net_sales'] as $key) {
            $this->assertEqualsWithDelta((float) $after['summary'][$key], $k[$key], 0.001, "website dashboard $key = database");
        }

        // The app's owner screens, the staff dashboard and the reports: same numbers.
        $owner = json_decode($this->asAppUser($this->fx['owner'], 'select public.owner_sales_summary(1)::text'), true);
        $row = collect($owner['branches'])->firstWhere('branch_id', $a);
        $this->assertEqualsWithDelta((float) $after['summary']['net_sales'], (float) $row['today_revenue'], 0.001, 'owner app = website');
        $this->assertEqualsWithDelta((float) $after['summary']['refunds'], (float) $row['today']['refunds'], 0.001);
        $staff = json_decode($this->asAppUser($this->fx['owner'], 'select public.staff_get_dashboard(?::uuid)::text', [$a]), true);
        $this->assertEqualsWithDelta((float) $after['summary']['net_sales'], (float) $staff['sales_today'], 0.001, 'staff app = website');
        $report = $this->actingAs($admin)->get("/s/reports?branch=$a&from=$today&to=$today")->assertOk()->viewData('report');
        $this->assertEqualsWithDelta((float) $after['summary']['net_sales'], (float) $report['summary']['net_sales'], 0.001, 'reports = dashboard');

        // Staff Sales page (own branch, sales_overview) = owner Sales page (owner_sales_summary) for the same 30 days.
        $staffSales = $this->actingAs($this->portalStaff())->get('/s/sales?days=30')->assertOk()->viewData('summary');
        $ownerSales = $this->actingAs($admin)->get('/s/sales?days=30')->assertOk()->viewData('summary');
        $this->assertEqualsWithDelta((float) collect($ownerSales['branches'])->firstWhere('branch_id', $a)['window_revenue'],
            (float) collect($staffSales['branches'])->firstWhere('branch_id', $a)['window_revenue'], 0.001, 'staff page = owner page');

        // CSV = screen, with the refund columns.
        $csv = $this->actingAs($admin)->get("/reports/export?branch=$a&from=$today&to=$today&section=by_day")->streamedContent();
        $lines = array_map('str_getcsv', array_values(array_filter(explode("\n", trim(preg_replace('/^\xEF\xBB\xBF/', '', $csv))))));
        $cols = array_flip($lines[0]);
        $this->assertSame($today, $lines[1][$cols['date']]);
        foreach (['gross_sales', 'discounts', 'refunds', 'refund_count', 'net_sales'] as $key) {
            $this->assertEqualsWithDelta((float) $report['by_day'][0][$key], (float) $lines[1][$cols[$key]], 0.001, "CSV $key = screen");
        }

        // Points: half of the 4 earned are reversed (proportional), once; the customer sees it.
        $this->assertSame(2, (int) $this->db()->selectOne('select points_balance from public.loyalty_accounts where firebase_uid = ?', [$this->fx['customer']])->points_balance);
        $mine = collect(json_decode($this->asAppUser($this->fx['customer'], 'select public.get_my_order_refunds()::text'), true))->firstWhere('order_id', $order);
        $this->assertSame(['partial', 100.0, 2], [$mine['state'], (float) $mine['refunded_amount'], (int) $mine['points_reversed']]);

        // Orders and payments pages show the partial refund from the database.
        $rows = $this->actingAs($admin)->get('/orders?fresh=1')->assertOk()->viewData('orders');
        $this->assertSame(['Partially refunded', 100.0], [collect($rows)->firstWhere('id', $order)['statusLabel'], (float) collect($rows)->firstWhere('id', $order)['refunded']]);
        $this->actingAs($admin)->get('/admin/payments?branch='.$a)->assertOk()->assertSee('Partially refunded')->assertSee('net sales');

        // The decision is in the app's audit log exactly once, and in the website's log.
        $this->assertSame(1, (int) $this->db()->selectOne("select count(*) as n from public.staff_audit_logs where entity_id = ? and action like 'refund.%'", [$refund])->n);
        $this->assertTrue(ActivityLog::where('action', 'refund.approved_cash')->exists());
    }

    public function test_reports_need_the_view_reports_permission_for_staff(): void
    {
        $staff = $this->portalStaff();
        $this->actingAs($staff)->get('/s/reports')->assertStatus(403)->assertSee('permission to view reports');

        $this->db()->insert("insert into public.staff_permission_grants (firebase_uid, permission) values (?, 'view_reports')", [$this->fx['staff_a']]);
        // Staff are pinned to their own branch whatever the query string says.
        $this->actingAs($staff)->get('/s/reports?branch='.$this->fx['branch_b'])->assertOk()
            ->assertSee($this->fx['branch_a_name'])->assertDontSee($this->fx['branch_b_name']);
    }

    public function test_forecast_is_honest_without_history_and_evaluated_with_history(): void
    {
        $admin = $this->portalAdmin();
        $this->actingAs($admin)->get('/reports/forecast?run=1&branch='.$this->fx['branch_b'])->assertOk()->assertSee('Not enough history yet');

        $this->seedHistory('a', 45);
        $page = $this->actingAs($admin)->get('/reports/forecast?run=1&branch='.$this->fx['branch_a'].'&variant='.$this->fx['variant'].'&horizon=7');
        $page->assertOk()->assertSee('Hold-out error (MAE)')->assertSee('Model is better')->assertSee('Forecasts are estimates, not guaranteed sales.');

        $save = $this->actingAs($admin)->post(route('reports.forecast.save'), [
            'branch' => $this->fx['branch_a'], 'variant' => $this->fx['variant'], 'metric' => 'units', 'granularity' => 'day', 'horizon' => 7,
        ]);
        $save->assertRedirect();
        $this->actingAs($admin)->get($save->headers->get('Location'))->assertOk()->assertSee('Real error so far')->assertSee('not yet');
        $this->assertTrue(ActivityLog::where('action', 'forecast.saved')->exists());
    }

    public function test_cash_drawer_page_shows_shift_sales_and_voids_from_the_app(): void
    {
        $shift = json_decode($this->asAppUser($this->fx['staff_a'], 'select public.staff_open_shift(?::uuid, 500)::text', [$this->fx['branch_a']]), true);
        $sale = json_decode($this->asAppUser($this->fx['staff_a'],
            "select public.staff_create_pos_sale(?::uuid, jsonb_build_array(jsonb_build_object('variant_id', ?::text, 'quantity', 2)), 'cash', null, 500)::text",
            [$this->fx['branch_a'], $this->fx['variant']]), true);
        $this->asAppUser($this->fx['owner'], "select public.staff_void_pos_sale(?, 'Rang the wrong item')::text", [$sale['order_id']]);

        $this->actingAs($this->portalAdmin())->get('/s/cash-drawer?branch='.$this->fx['branch_a'])->assertOk()
            ->assertSee($shift['session_id'])->assertSee('IT Staff A')
            ->assertSee('Refunds and voids · 1 void(s)')
            ->assertSee('₱500.00');   // expected cash: 500 opening + 200 sale - 200 void
    }

    public function test_a_live_delivery_run_never_reaches_the_website(): void
    {
        // A real run made in the app (customer pin, rider out, live GPS point): the website shows
        // none of it. No delivery pages or JSON, no rider name, no coordinates, no address.
        $db = $this->db();
        $addr = $db->selectOne("insert into public.customer_addresses (firebase_uid, recipient_name, phone, line1, city, latitude, longitude)
            values (?, 'IT', '0917', '1 Pin St', 'Calamba', 14.20111, 121.16222) returning id", [$this->fx['customer']])->id;
        $cart = json_decode($this->asAppUser($this->fx['customer'],
            "select public.sync_customer_cart(?::uuid, jsonb_build_array(jsonb_build_object('product_id', ?::text, 'variant_id', ?::text, 'quantity', 1)), null, false)::text",
            [$this->fx['branch_a'], $this->fx['product'], $this->fx['variant']]), true)['cart_id'];
        $order = $this->asAppUser($this->fx['customer'], "select public.place_order(?::uuid, true, ?::uuid, 'Cash on Delivery', '', ?)", [$cart, $addr, Str::uuid()->toString()]);
        $this->asAppUser($this->fx['owner'], "select public.staff_update_order_status(?, 'confirmed')::text", [$order]);
        $driver = "it-drv-{$this->sfx}";
        $this->asAppUser($this->fx['owner'], "select public.owner_upsert_driver(?, 'IT Rider', 'r@x', ?::uuid)::text", [$driver, $this->fx['branch_a']]);
        $run = json_decode($this->asAppUser($this->fx['staff_a'], "select public.staff_create_delivery(?::uuid, 'Motorbike', 'TBD', array[?])::text", [$this->fx['branch_a'], $order]), true)['id'];
        $this->asAppUser($this->fx['staff_a'], 'select public.staff_assign_driver(?, ?)::text', [$run, $driver]);
        $this->asAppUser($driver, "select public.driver_respond_assignment(?, 'accept')::text", [$run]);
        $this->asAppUser($driver, 'select public.driver_mark_picked_up(?)::text', [$run]);
        $this->asAppUser($driver, 'select public.driver_post_location(?, 14.2117, 121.1653)::text', [$run]);

        $admin = $this->portalAdmin();
        foreach (['/dashboard/drivers.json', '/s/driver-tracking', '/s/deliveries'] as $url) {
            $this->actingAs($admin)->get($url)->assertNotFound();
        }
        \App\Support\SupabaseTimer::$log = [];
        foreach (['/dashboard', '/orders', '/admin/users'] as $url) {
            $this->actingAs($admin)->get($url)->assertOk()->assertDontSee('IT Rider')->assertDontSee('14.2117')
                ->assertDontSee('14.20111')->assertDontSee('1 Pin St')->assertDontSee($run);
        }
        $fns = implode(' ', array_column(\App\Support\SupabaseTimer::$log, 'fn'));
        foreach (['staff_get_deliveries', 'staff_active_driver_positions', 'staff_list_drivers'] as $fn) {
            $this->assertStringNotContainsString($fn, $fns);
        }

        // The order itself is still listed as a read-only delivery sale, and cannot be moved from here.
        $this->actingAs($admin)->postJson("/orders/$order/advance", ['from' => 'outForDelivery'])->assertStatus(422);
    }

    public function test_inventory_page_shows_reorder_suggestions_and_expiring_batches(): void
    {
        $this->seedHistory('a', 30);
        $this->asAppUser($this->fx['owner'], "select public.staff_receive_batch(?::uuid, ?::uuid, ?, 5, (now() at time zone 'Asia/Manila')::date + 5)::text",
            [$this->fx['branch_a'], $this->fx['variant'], "EXP-{$this->sfx}"]);

        $this->actingAs($this->portalAdmin())->get('/s/inventory?branch='.$this->fx['branch_a'])->assertOk()
            ->assertSee('Reorder suggestions')->assertSee('Order ')            // fast seller with ~55 units on hand
            ->assertSee("EXP-{$this->sfx}")->assertSee('5 days left');
    }

    // ---- RFID loyalty cards (20261011000000_loyalty_cards.sql) ------------------------------

    public function test_card_is_linked_tapped_blocked_and_replaced_through_the_portal(): void
    {
        $admin = $this->portalAdmin();
        $staff = $this->portalStaff();
        $uid = strtoupper(bin2hex(random_bytes(4)));
        $new = strtoupper(bin2hex(random_bytes(5)));
        $cust = $this->fx['customer'];

        // Unknown card
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => $uid])->assertOk()->assertJson(['status' => 'unregistered']);
        // Staff find the customer by exact phone? (phone '0917' is too short) -> by e-mail
        $this->actingAs($staff)->post('/cards/find', ['query' => "cust-{$this->sfx}@test.local"])->assertRedirect("/cards/customer/{$cust}");
        $this->actingAs($staff)->post('/cards/find', ['query' => 'cust-'])->assertSessionHas('error');

        // Link (double submit with the same key links once)
        $page = $this->actingAs($staff)->get("/cards/customer/{$cust}")->assertOk()->assertSee('Link a card');
        $key = 'k'.Str::random(20);
        $this->actingAs($staff)->post("/cards/customer/{$cust}/register", ['card_uid' => implode(':', str_split($uid, 2)), 'request_key' => $key])
            ->assertRedirect()->assertSessionHas('status');
        $this->actingAs($staff)->post("/cards/customer/{$cust}/register", ['card_uid' => $uid, 'request_key' => $key])->assertSessionHas('status');
        $db = $this->db();
        $this->assertSame(1, (int) $db->selectOne('select count(*) as n from public.loyalty_cards where firebase_uid = ?', [$cust])->n);
        $label = $db->selectOne('select card_label from public.loyalty_cards where firebase_uid = ?', [$cust])->card_label;
        $this->assertSame($label, $db->selectOne('select rfid_card_number from public.customer_profiles where firebase_uid = ?', [$cust])->rfid_card_number);

        // Tap -> customer
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => strtolower($uid)])->assertOk()
            ->assertJson(['status' => 'active', 'customer' => ['firebase_uid' => $cust]]);
        // Garbage is refused before reaching the database
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => "x' or 1=1"])->assertStatus(422);

        // Owner list shows it; staff cannot see the list (page still works)
        $this->actingAs($admin)->get('/cards')->assertOk()->assertSee($label)->assertSee('All cards');
        $this->actingAs($staff)->get('/cards')->assertOk()->assertDontSee('All cards');

        // Block (staff) -> tap says blocked; staff cannot unblock; owner can
        $cardId = $db->selectOne('select id from public.loyalty_cards where firebase_uid = ?', [$cust])->id;
        $this->actingAs($staff)->post("/cards/{$cardId}/block", ['reason' => 'reported lost'])->assertSessionHas('status');
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => $uid])->assertJson(['status' => 'blocked'])->assertJsonMissing(['firebase_uid' => $cust]);
        $this->actingAs($staff)->post("/cards/{$cardId}/unblock")->assertSessionHas('error');
        $this->actingAs($admin)->get("/cards/customer/{$cust}")->assertSee('Unblock (card found)');

        // Replace the blocked card
        $this->actingAs($staff)->post("/cards/customer/{$cust}/replace", ['card_uid' => $new, 'reason' => 'lost', 'request_key' => 'r'.Str::random(20)])
            ->assertSessionHas('status');
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => $uid])->assertJson(['status' => 'replaced']);
        $this->actingAs($staff)->postJson('/cards/tap', ['card_uid' => $new])->assertJson(['status' => 'active']);
        $this->actingAs($admin)->get("/cards/customer/{$cust}")->assertOk()->assertSee('Replaced')->assertSee('Registered');
        $this->assertTrue(ActivityLog::where('action', 'loyalty.card_replaced')->exists());
    }

    public function test_card_pages_are_not_available_in_demo_mode(): void
    {
        config(['melai.data_source' => 'mock']);
        $this->actingAs($this->portalAdmin())->get('/cards')->assertNotFound();
    }

    // ---- suppliers + purchase receipts with OCR (20261011010000) -----------------------------

    public function test_ocr_invoice_becomes_a_draft_and_only_approval_posts_stock_once(): void
    {
        \Illuminate\Support\Facades\Storage::fake('local');
        $staff = $this->portalStaff();
        $db = $this->db();
        $stock = fn () => (int) $db->selectOne('select quantity from public.branch_inventory where branch_id = ? and variant_id = ?',
            [$this->fx['branch_a'], $this->fx['variant']])->quantity;
        $before = $stock();

        // Supplier
        $this->actingAs($staff)->post('/suppliers', ['name' => "IT-{$this->sfx} Nut Traders", 'email' => 'sales@nuts.test'])->assertSessionHas('status');
        $supplier = $db->selectOne('select id from public.suppliers where name = ?', ["IT-{$this->sfx} Nut Traders"])->id;

        // Scan: OCR text + photo -> draft (no stock yet)
        $inv = 'SI-'.random_int(100000, 999999);
        $ocr = "IT-{$this->sfx} NUT TRADERS\nSALES INVOICE No. {$inv}\nDate: ".now('Asia/Manila')->subDay()->format('m/d/Y')
            ."\nIT-{$this->sfx} Garlic Peanuts   12   80.00   960.00\nMystery Item 2 50.00 100.00\nTOTAL 1,060.00";
        $photo = \Illuminate\Http\UploadedFile::fake()->image('invoice.jpg', 800, 1200);
        $res = $this->actingAs($staff)->post('/receipts', ['branch_id' => $this->fx['branch_a'], 'ocr_text' => $ocr, 'ocr_confidence' => 88.5, 'photo' => $photo]);
        $res->assertRedirect()->assertSessionHas('status');
        $id = basename(parse_url($res->headers->get('Location'), PHP_URL_PATH));
        $r = $db->selectOne('select * from public.purchase_receipts where id = ?', [$id]);
        $this->assertSame('draft', $r->status);
        $this->assertSame('ocr', $r->source);
        $this->assertSame($supplier, $r->supplier_id, 'supplier detected from the invoice header');
        $this->assertSame($inv, $r->supplier_invoice_no);
        $this->assertEquals(1060, (float) $r->invoice_total);
        $lines = $db->select('select * from public.purchase_receipt_lines where receipt_id = ? order by line_no', [$id]);
        $this->assertCount(2, $lines);
        $this->assertSame($this->fx['variant'], $lines[0]->variant_id, 'product matched by name');
        $this->assertSame([12, 80.0], [$lines[0]->quantity, (float) $lines[0]->unit_cost]);
        $this->assertNull($lines[1]->variant_id, 'unknown product left for the reviewer');
        $this->assertSame($before, $stock(), 'a draft never posts stock');
        \Illuminate\Support\Facades\Storage::disk('local')->assertExists($r->document_path);

        $this->actingAs($staff)->get("/receipts/{$id}")->assertOk()->assertSee('match a product')->assertSee('Approve');
        $this->actingAs($staff)->get("/receipts/{$id}/image")->assertOk();

        // Approving as scanned is refused (line 2 has no product, no expiry)
        $form = fn (array $extra = []) => array_merge([
            'branch_id' => $this->fx['branch_a'], 'supplier_id' => $supplier, 'supplier_invoice_no' => $inv,
            'invoice_date' => now('Asia/Manila')->subDay()->toDateString(), 'invoice_total' => 960,
            'lines' => [['raw_text' => $lines[0]->raw_text, 'description' => 'Garlic Peanuts', 'variant_id' => $this->fx['variant'],
                'quantity' => 12, 'unit_cost' => 80, 'expiration_date' => now('Asia/Manila')->addMonths(4)->toDateString()]],
        ], $extra);
        $this->actingAs($staff)->post("/receipts/{$id}", $form(['lines' => [['description' => 'x', 'quantity' => 2]], 'action' => 'approve']))
            ->assertSessionHas('error');
        $this->assertSame($before, $stock());

        // Reviewer removes the unknown line, sets expiry, approves
        $this->actingAs($staff)->post("/receipts/{$id}", $form(['action' => 'approve', 'request_key' => 'approve-'.$this->sfx]))->assertSessionHas('status');
        $this->assertSame($before + 12, $stock());
        $this->assertSame('approved', $db->selectOne('select status from public.purchase_receipts where id = ?', [$id])->status);
        $this->actingAs($staff)->get("/receipts/{$id}")->assertOk()->assertDontSee('Approve &amp; receive', false)->assertSee($r->receipt_code);

        // Double submit of the approve form: no second posting
        $this->actingAs($staff)->post("/receipts/{$id}", $form(['action' => 'approve', 'request_key' => 'approve-'.$this->sfx]))->assertSessionHas('error');
        $this->assertSame($before + 12, $stock());

        // A second scan of the same invoice cannot be approved
        $res2 = $this->actingAs($staff)->post('/receipts', ['branch_id' => $this->fx['branch_a'], 'ocr_text' => $ocr]);
        $id2 = basename(parse_url($res2->headers->get('Location'), PHP_URL_PATH));
        $this->actingAs($staff)->post("/receipts/{$id2}", $form(['action' => 'approve']))->assertSessionHas('error');
        $this->assertSame($before + 12, $stock());

        $this->actingAs($staff)->get('/receipts')->assertOk()->assertSee($r->receipt_code);
        $this->assertTrue(ActivityLog::where('action', 'purchase_receipt.approved')->exists());
    }

    public function test_staff_without_inventory_permission_cannot_receive_stock(): void
    {
        $db = $this->db();
        $uid = "it-cash-{$this->sfx}";
        $db->insert("insert into public.staff_members (firebase_uid, full_name, email, role, branch_id, account_status, can_manage_inventory)
                     values (?, 'IT Cashier', ?, 'staff', ?, 'active', false)", [$uid, "cash-{$this->sfx}@test.local", $this->fx['branch_a']]);
        $u = User::factory()->create(['email' => "cash-{$this->sfx}@test.local", 'role' => 'staff', 'has_access' => true]);
        $u->forceFill(['staff_uid' => $uid, 'firebase_uid' => $uid, 'firebase_email_verified' => true])->save();

        $this->actingAs($u)->post('/receipts', ['branch_id' => $this->fx['branch_a'], 'ocr_text' => 'Garlic 1 10.00 10.00'])->assertSessionHas('error');
        $this->actingAs($u)->post('/suppliers', ['name' => "IT-{$this->sfx} X"])->assertSessionHas('error');
    }

    // ---- HitPay Refund API (20261011020000) --------------------------------------------------

    /** An order paid online through HitPay (the webhook's SQL path), completed, with a refund approved in the portal. */
    private function approvedHitpayRefund(string $payId): array
    {
        $order = $this->placeOrder('a', 'Online Payment (GCash, Maya, Card)');
        $db = $this->db();
        $db->select('select public.hitpay_set_checkout(?, ?, ?)', [$order, "preq-{$this->sfx}", 'https://pay.test/x']);
        $db->select("select public.hitpay_apply_payment(?, 'success', 'GCash', ?, null)", [$order, $payId]);
        foreach (['confirmed', 'preparing', 'readyForPickup', 'completed'] as $st) {
            $this->asAppUser($this->fx['owner'], 'select public.staff_update_order_status(?, ?)::text', [$order, $st]);
        }
        $refund = $this->requestRefund($order, 1);
        $this->actingAs($this->portalAdmin())->post(route('admin.refunds.approve', $order))->assertSessionHas('status');

        return [$order, $refund];
    }

    public function test_online_refund_is_sent_through_the_hitpay_api_once(): void
    {
        config(['services.hitpay.api_key' => 'test-key', 'services.hitpay.env' => 'sandbox']);
        \Illuminate\Support\Facades\Http::fake([
            'api.sandbox.hit-pay.com/v1/refund' => \Illuminate\Support\Facades\Http::response(
                ['id' => "rf-{$this->sfx}", 'payment_id' => "pay-{$this->sfx}", 'amount_refunded' => 100, 'status' => 'succeeded'], 200),
        ]);
        [$order, $refund] = $this->approvedHitpayRefund("pay-{$this->sfx}");
        $admin = User::where('email', "owner-{$this->sfx}@test.local")->first();

        $this->actingAs($admin)->get('/admin/refunds')->assertSee('via HitPay');
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHas('status');

        \Illuminate\Support\Facades\Http::assertSent(fn ($req) => $req->url() === 'https://api.sandbox.hit-pay.com/v1/refund'
            && $req['payment_id'] === "pay-{$this->sfx}" && (float) $req['amount'] === 100.0
            && $req->header('X-BUSINESS-API-KEY')[0] === 'test-key');
        $db = $this->db();
        $this->assertSame('completed', $db->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $this->assertSame('refunded', $db->selectOne('select status from public.payments where order_id = ?', [$order])->status);
        $this->assertSame("rf-{$this->sfx}", $db->selectOne('select gateway_refund_id from public.refund_gateway_attempts where refund_id = ?', [$refund])->gateway_refund_id);

        // Pressing the button again cannot send a second refund.
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHasErrors('refund');
        \Illuminate\Support\Facades\Http::assertSentCount(1);
    }

    public function test_hitpay_refusal_keeps_the_refund_approved_and_a_timeout_blocks_a_blind_retry(): void
    {
        config(['services.hitpay.api_key' => 'test-key']);
        [$order, $refund] = $this->approvedHitpayRefund("pay2-{$this->sfx}");
        $admin = User::where('email', "owner-{$this->sfx}@test.local")->first();
        $db = $this->db();

        // One fake whose answer we switch per step (Http::fake() stubs stack up).
        $mode = 'refuse';
        \Illuminate\Support\Facades\Http::fake(function ($req) use (&$mode) {
            return match ($mode) {
                'refuse' => \Illuminate\Support\Facades\Http::response(['message' => 'Insufficient balance'], 422),
                'timeout' => throw new \Illuminate\Http\Client\ConnectionException('timed out'),
                default => str_ends_with($req->url(), '/v1/refund')
                    ? \Illuminate\Support\Facades\Http::response(['id' => "rf2-{$this->sfx}", 'status' => 'pending'], 200)
                    : \Illuminate\Support\Facades\Http::response(['id' => "rf2-{$this->sfx}", 'status' => 'succeeded'], 200),
            };
        });

        // 1. HitPay refuses (4xx): attempt failed, refund still approved, can retry
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHas('error');
        $this->assertSame('approved', $db->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $this->assertSame('Insufficient balance', $db->selectOne("select error from public.refund_gateway_attempts where refund_id = ? and status = 'failed'", [$refund])->error);

        // 2. No answer: attempt stays "sending" and blocks another send
        $mode = 'timeout';
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHas('error');
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHas('error');
        $this->assertSame(1, (int) $db->selectOne("select count(*) as n from public.refund_gateway_attempts where refund_id = ? and status = 'sending'", [$refund])->n);
        $this->actingAs($admin)->get('/admin/refunds')->assertSee('Close attempt');

        // 3. Pending answer then "Check HitPay" -> completed
        $attempt = $db->selectOne("select id from public.refund_gateway_attempts where refund_id = ? and status = 'sending'", [$refund])->id;
        $db->update("update public.refund_gateway_attempts set started_at = now() - interval '10 minutes' where id = ?", [$attempt]);
        // An attempt that is not this order's refund is refused (it would be logged under the wrong order).
        $this->actingAs($admin)->post(route('admin.refunds.hitpay.abandon', $order), ['attempt_id' => (string) \Illuminate\Support\Str::uuid(), 'note' => 'Dashboard shows no refund'])
            ->assertSessionHasErrors('attempt_id');
        $this->assertSame('sending', $db->selectOne('select status from public.refund_gateway_attempts where id = ?', [$attempt])->status);
        $this->actingAs($admin)->post(route('admin.refunds.hitpay.abandon', $order), ['attempt_id' => $attempt, 'note' => 'Dashboard shows no refund'])->assertSessionHas('status');
        $mode = 'pending-then-ok';
        $this->actingAs($admin)->post(route('admin.refunds.hitpay', $order))->assertSessionHas('status');
        $this->assertSame('approved', $db->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
        $pending = $db->selectOne("select id from public.refund_gateway_attempts where refund_id = ? and status = 'pending'", [$refund])->id;
        $this->actingAs($admin)->get('/admin/refunds')->assertSee('Check HitPay');
        $this->actingAs($admin)->post(route('admin.refunds.hitpay.check', $order), ['attempt_id' => $pending])->assertSessionHas('status');
        $this->assertSame('completed', $db->selectOne('select status from public.refund_requests where id = ?', [$refund])->status);
    }
}

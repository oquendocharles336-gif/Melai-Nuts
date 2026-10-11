<?php

namespace Tests\Feature;

use App\Services\AdminActions;
use App\Services\Supabase\SupabaseGateway;
use App\Support\Swr;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\PerfSupabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * The stale-while-revalidate cache (App\Support\Swr) must never show data from before a change,
 * never share one account's data with another, and never skip the account check.
 */
class CacheSafetyTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private PerfSupabase $perf;

    private function boot(): void
    {
        $this->useFakeSupabase();
        config(['melai.dashboard.cache_seconds' => 45, 'melai.cache.stale_seconds' => 300]);
        $this->perf = PerfSupabase::build($this->db, 0);
        $this->perf->orders = $this->db->orders; // ORD-CAL-1 (b-cal), ORD-LB-1 (b-lb)
        // staff_update_order_status changes the fake order like the real function would.
        $this->perf->override = function (string $fn, array $b) {
            if ($fn !== 'staff_update_order_status') {
                return null;
            }
            foreach ($this->perf->orders as &$o) {
                if ($o['id'] === $b[0]) {
                    $o['status'] = $b[1];
                }
            }

            return false; // void
        };
        $this->db = $this->perf;
        $this->app->instance(SupabaseGateway::class, $this->perf);
    }

    private function statusOnOrdersPage($user, string $id): ?string
    {
        $rows = $this->signedIn($user)->get('/orders')->assertOk()->viewData('orders');

        return collect($rows)->firstWhere('id', $id)['status'] ?? null;
    }

    public function test_moving_an_order_never_leaves_the_old_status_on_screen(): void
    {
        $this->boot();
        $this->perf->orders[0]['status'] = 'pending';
        $owner = $this->linkedLogin('uid-owner');

        $this->assertSame('pending', $this->statusOnOrdersPage($owner, 'ORD-CAL-1'));
        $this->assertSame(1, $this->signedIn($owner)->getJson('/dashboard/overview.json?range=7')->json('pipeline.counts.new'));
        $this->assertSame(1, $this->signedIn($owner)->getJson('/ui/counts.json')->json('orders'));

        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'pending'])->assertOk()->assertJsonPath('order.status', 'confirmed');
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'confirmed'])->assertOk()->assertJsonPath('order.status', 'preparing');

        // Everything cached before the change is obsolete at once (well inside the 45 s fresh time).
        $this->assertSame('preparing', $this->statusOnOrdersPage($owner, 'ORD-CAL-1'));
        $this->assertSame(1, $this->signedIn($owner)->getJson('/dashboard/overview.json?range=7')->json('pipeline.counts.packing'));
        $this->assertSame(0, $this->signedIn($owner)->getJson('/dashboard/overview.json?range=7')->json('pipeline.counts.new'));
    }

    public function test_a_change_by_one_account_invalidates_every_accounts_cache(): void
    {
        $this->boot();
        $this->perf->orders[0]['status'] = 'pending';
        $owner = $this->linkedLogin('uid-owner');
        $cora = $this->linkedLogin('uid-cal');

        $this->assertSame('pending', $this->statusOnOrdersPage($cora, 'ORD-CAL-1')); // Cora's own cache
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'pending'])->assertOk();
        $this->assertSame('confirmed', $this->statusOnOrdersPage($cora, 'ORD-CAL-1'));
    }

    public function test_cache_keys_are_per_login_and_app_account_and_never_shared(): void
    {
        $this->boot();
        $owner = $this->linkedLogin('uid-owner');
        $cora = $this->linkedLogin('uid-cal');
        $lito = $this->linkedLogin('uid-lb');

        // The owner warms every cache first; each staff member still gets only their own branch.
        $this->signedIn($owner)->get('/orders')->assertOk();
        $this->assertSame(2, $this->signedIn($owner)->getJson('/ui/counts.json')->json('orders') + 2); // both branches are completed orders
        $coraRows = $this->signedIn($cora)->get('/orders')->assertOk()->viewData('orders');
        $litoRows = $this->signedIn($lito)->get('/orders')->assertOk()->viewData('orders');
        $this->assertSame(['ORD-CAL-1'], array_column($coraRows, 'id'));
        $this->assertSame(['ORD-LB-1'], array_column($litoRows, 'id'));
        $this->assertSame('Calamba Branch', $this->signedIn($cora)->getJson('/dashboard/overview.json')->json('scope'));

        // Every read Cora caused ran as Cora's own UID (the database decided what she sees).
        $this->assertSame(['uid-cal'], array_values(array_unique(array_column(
            array_filter($this->perf->calls, fn ($c) => in_array($c['fn'], ['admin_portal_orders', 'get_my_staff_context'], true) && $c['uid'] === 'uid-cal'), 'uid'))));

        // The key itself names the login and the app account.
        $this->actingAs($owner);
        $ownerKey = Swr::key('orders-page');
        $this->actingAs($cora);
        $this->assertNotSame($ownerKey, Swr::key('orders-page'));
        $same = $cora->replicate()->forceFill(['staff_uid' => 'uid-lb']);
        $same->id = $cora->id;
        $this->actingAs($same);
        $this->assertNotSame(Swr::key('orders-page'), $ownerKey, 'a re-linked login gets new keys');
    }

    public function test_a_deactivated_account_is_cut_off_even_when_everything_is_cached(): void
    {
        $this->boot();
        $owner = $this->linkedLogin('uid-owner');
        foreach (['/orders', '/ui/counts.json', '/dashboard/overview.json'] as $url) {
            $this->signedIn($owner)->get($url, ['Accept' => 'application/json'])->assertOk();
        }
        $this->db->staff['uid-owner']['account_status'] = 'inactive';
        $this->signedIn($owner)->getJson('/ui/counts.json')->assertUnauthorized();
        $this->signedIn($owner)->getJson('/dashboard/overview.json')->assertUnauthorized();
        $this->signedIn($owner)->get('/orders')->assertRedirect(route('login'));
    }

    public function test_stale_answers_are_served_at_once_marked_and_fresh_1_reloads(): void
    {
        $this->boot();
        $owner = $this->linkedLogin('uid-owner');
        $this->perf->orders[0]['status'] = 'pending';
        $this->signedIn($owner)->getJson('/ui/counts.json')->assertOk()->assertHeaderMissing('X-Melai-Stale');
        $this->perf->orders[0]['status'] = 'cancelled'; // changed in the app, not through the website

        $this->travel(60)->seconds(); // past fresh (45 s), inside stale (300 s)
        $this->signedIn($owner)->getJson('/ui/counts.json')->assertOk()->assertHeader('X-Melai-Stale', '1')->assertJsonPath('orders', 1);
        $this->signedIn($owner)->getJson('/ui/counts.json?fresh=1')->assertOk()->assertHeaderMissing('X-Melai-Stale')->assertJsonPath('orders', 0);

        $this->travel(400)->seconds(); // past stale: never served
        $this->perf->orders[0]['status'] = 'pending';
        $this->signedIn($owner)->getJson('/ui/counts.json')->assertOk()->assertHeaderMissing('X-Melai-Stale')->assertJsonPath('orders', 1);
    }

    public function test_only_successful_changes_bump_the_data_version(): void
    {
        $this->boot();
        $owner = $this->linkedLogin('uid-owner');
        $v = AdminActions::version();
        $this->signedIn($owner)->postJson('/stock/receive', ['quantity' => 0])->assertStatus(422); // validation failed
        $this->signedIn($owner)->post('/cards/find', ['q' => 'x']); // a read that happens to be a POST
        $this->assertSame($v, AdminActions::version());
        $this->signedIn($owner)->post(route('admin.payments.mark-paid', 'ORD-CAL-1'), []); // any change attempt that succeeds or redirects
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'completed']); // 422: no next stage
        $this->perf->orders[0]['status'] = 'pending';
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'pending'])->assertOk();
        $this->assertGreaterThan($v, AdminActions::version());
    }
}

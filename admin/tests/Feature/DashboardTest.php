<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

class DashboardTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_admin_sees_all_sections_for_each_period(): void
    {
        $this->actingAs(User::factory()->create(['role' => 'admin', 'has_access' => true]));
        foreach (['today', 'week', 'month'] as $p) {
            $this->get("/dashboard?period=$p")->assertOk()
                ->assertSee('Sales per branch')->assertSee('Stock levels per branch')
                ->assertSee('Pending refunds')->assertSee('Lowest stock')
                ->assertDontSee('Driver and delivery tracking')->assertDontSee('Deliveries in progress');
        }
    }

    public function test_the_old_drivers_endpoint_is_gone(): void
    {
        $this->actingAs(User::factory()->create(['has_access' => true]))->getJson('/dashboard/drivers.json')->assertNotFound();
    }

    public function test_branch_filter_and_today_figures(): void
    {
        $this->actingAs(User::factory()->create(['role' => 'admin', 'has_access' => true]));

        $all = $this->get('/dashboard?period=week')->assertOk()->assertSee('All branches')->assertSee('Net sales today')->assertSee('Top branches');
        $this->assertCount(3, $all->viewData('sales'));
        $this->assertNull($all->viewData('branchId'));

        $one = $this->get('/dashboard?period=week&branch=branch-calamba')->assertOk()->assertSee('Overview this week · Calamba Branch');
        $this->assertSame(['branch-calamba'], array_column($one->viewData('sales'), 'id'));
        $this->assertArrayNotHasKey('deliveries', $one->original->getData()); // no delivery data on the website
        $this->assertLessThanOrEqual($all->viewData('kpis')['gross_sales'], $one->viewData('kpis')['gross_sales']);

        $this->assertNull($this->get('/dashboard?branch=not-a-branch')->assertOk()->viewData('branchId'));
    }

    public function test_live_numbers_are_cached_briefly_per_account_and_fresh_skips_the_cache(): void
    {
        $this->useFakeSupabase();
        config(['melai.dashboard.cache_seconds' => 45]);
        $owner = $this->linkedLogin('uid-owner');
        // The dashboard's own orders query (period "today"); the sidebar's refund badge reads its own 90-day window.
        $orderCalls = fn () => collect($this->db->calls)->where('fn', 'admin_portal_orders')
            ->filter(fn ($c) => str_starts_with($c['bindings'][0], now()->startOfDay()->format('Y-m-d\\TH:i:s')))->count();

        $first = $this->signedIn($owner)->get('/dashboard')->assertOk()->viewData('kpis')['orders'];
        $calls = $orderCalls();
        $this->assertSame(1, $calls);
        $this->db->addOrder('ORD-NEW', 'b-cal', 99);

        $this->assertSame($first, $this->signedIn($owner)->get('/dashboard')->assertOk()->viewData('kpis')['orders'], 'served from the cache');
        $this->assertSame($calls, $orderCalls(), 'the orders query was not run again');
        $this->assertContains('get_my_staff_context', $this->db->calledFunctions('uid-owner'), 'the account is still checked on every request');

        $this->assertSame($first + 1, $this->signedIn($owner)->get('/dashboard?fresh=1')->viewData('kpis')['orders']);

        // Another account gets its own (scoped) numbers, never the owner's cache.
        $cora = $this->linkedLogin('uid-cal');
        $this->assertSame(2, $this->signedIn($cora)->get('/dashboard')->assertOk()->viewData('kpis')['orders']);

        // A deactivated owner is cut off at once, cache or not.
        $this->db->staff['uid-owner']['account_status'] = 'inactive';
        $this->signedIn($owner)->get('/dashboard')->assertRedirect(route('login'));
    }

    public function test_database_unavailable_shows_the_retry_card_and_no_invented_numbers(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->db->offline = true;
        $this->signedIn($owner)->get('/dashboard')->assertStatus(503)->assertSee('Database unavailable')->assertSee('Try again')->assertDontSee('₱');
    }

    public function test_production_always_uses_supabase_even_with_data_source_mock_and_shows_no_demo_data(): void
    {
        $this->useFakeSupabase();
        $this->app['env'] = 'production';
        putenv('DATA_SOURCE=mock');
        $_ENV['DATA_SOURCE'] = $_SERVER['DATA_SOURCE'] = 'mock';
        // Drop the test suite's own fixture bindings: only the website's code decides.
        (new \App\Providers\AppServiceProvider($this->app))->register();
        $this->app->forgetScopedInstances();

        try {
            $this->assertInstanceOf(\App\Services\Data\SupabaseDataSource::class, app(\App\Contracts\DataSource::class));
            $this->assertTrue(app(\App\Services\Platform::class)->isSupabase());
            $this->assertNotInstanceOf(\Tests\Support\MockPlatform::class, app(\App\Services\Platform::class));
            $this->assertSame(['SupabaseDataSource.php'], array_map('basename', glob(app_path('Services/Data/*.php'))), 'no demo data source in the website code');
            $this->assertArrayNotHasKey('data_source', require config_path('melai.php'), 'no mock switch in the config');

            $owner = User::factory()->create(['email' => 'owner@melainuts.test', 'role' => 'admin', 'has_access' => true]);
            $owner->forceFill(['staff_uid' => 'uid-owner'])->save();
            $this->actingAs($owner)->get('/dashboard')->assertOk()
                ->assertSee('Calamba Branch')->assertDontSee('Santa Cruz Branch')   // fixture-only branch never appears
                ->assertDontSee('Test data');
            $this->assertContains('admin_portal_orders', $this->db->calledFunctions('uid-owner'), 'numbers come from the database');
        } finally {
            putenv('DATA_SOURCE');
            unset($_ENV['DATA_SOURCE'], $_SERVER['DATA_SOURCE']);
        }
    }

    public function test_no_route_or_view_offers_manual_linking(): void
    {
        foreach (\Illuminate\Support\Facades\File::allFiles(resource_path('views')) as $f) {
            $this->assertStringNotContainsString('Link my app account', $f->getContents(), $f->getRelativePathname());
            $this->assertStringNotContainsString('Account not linked', $f->getContents(), $f->getRelativePathname());
        }
        foreach (\Illuminate\Support\Facades\Route::getRoutes() as $route) {
            $this->assertNotSame(\App\Http\Controllers\AccountLinkController::class, explode('@', (string) $route->getActionName())[0]);
        }
        $this->assertFileDoesNotExist(app_path('Http/Controllers/AccountLinkController.php'));
        $this->actingAs(User::factory()->create(['has_access' => true]))->get('/account/link')->assertRedirect('/dashboard');
    }

    public function test_without_the_new_migration_the_staff_list_still_shows_and_no_activity_is_guessed(): void
    {
        $this->useFakeSupabase();
        $this->db->missing = ['owner_staff_overview'];
        $owner = $this->linkedLogin('uid-owner');

        $page = $this->signedIn($owner)->get('/dashboard')->assertOk()
            ->assertSee('Cora Cashier')->assertSee('Lito Cashier')->assertSee('run supabase/migrations/20261013000000_admin_portal_owner_overview.sql');
        $this->assertFalse($page->viewData('staffActivity'));
        $this->assertNull($page->viewData('staffSummary')['pos_net_sales'], 'unknown, not 0');
        $this->assertSame([], $page->viewData('topStaff'));
        $this->assertContains('admin_portal_staff_directory', $this->db->calledFunctions('uid-owner'));
    }
}

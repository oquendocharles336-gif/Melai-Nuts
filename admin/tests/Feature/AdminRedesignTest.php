<?php

namespace Tests\Feature;

use App\Models\User;
use App\Services\AdminActions;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/** The redesigned admin UI: Overview JSON, sidebar badges, Orders, Settings, roles and the write endpoints. */
class AdminRedesignTest extends TestCase
{
    use RefreshDatabase;

    private function admin(): User
    {
        return User::factory()->create(['role' => 'admin', 'has_access' => true]);
    }

    public function test_overview_json_is_range_aware_and_needs_access(): void
    {
        $this->getJson('/dashboard/overview.json')->assertUnauthorized();
        $this->actingAs(User::factory()->create(['has_access' => false]))->get('/dashboard/overview.json')->assertRedirect(route('waiting'));

        $this->actingAs($this->admin());
        foreach ([7, 30, 90] as $r) {
            $json = $this->getJson("/dashboard/overview.json?range=$r")->assertOk()
                ->assertJsonStructure(['range', 'revenue' => ['total', 'delta', 'series'], 'kpis' => ['orders', 'items', 'average', 'low'],
                    'pipeline' => ['counts' => ['new', 'packing', 'shipped', 'delivered']], 'channels', 'top', 'activity'])->json();
            $this->assertSame($r, $json['range']);
            $this->assertCount($r, $json['revenue']['series']);
            // The series adds up to the headline total (same money rules as the dashboard KPIs).
            $this->assertEqualsWithDelta($json['revenue']['total'], array_sum(array_column($json['revenue']['series'], 'value')), 0.05);
        }
        $this->assertSame(30, $this->getJson('/dashboard/overview.json?range=13')->json('range')); // unknown range -> 30
        $one = $this->getJson('/dashboard/overview.json?range=7&branch=branch-calamba')->assertOk();
        $this->assertSame('Calamba Branch', $one->json('scope'));
        $this->assertNull($this->getJson('/dashboard/overview.json?branch=nope')->json('branchId'));
    }

    public function test_nav_counts_hide_refunds_from_staff(): void
    {
        $this->actingAs($this->admin())->getJson('/ui/counts.json')->assertOk()->assertJsonStructure(['orders', 'low', 'refunds', 'month' => ['net', 'goal', 'pct']]);
        $this->actingAs(User::factory()->create(['role' => 'staff', 'has_access' => true]))->getJson('/ui/counts.json')->assertOk()->assertJsonPath('refunds', 0);
    }

    public function test_shell_hides_admin_items_from_staff(): void
    {
        $this->actingAs($this->admin())->get('/dashboard')->assertOk()->assertSee('All users', false)->assertSee('Overview');
        $this->actingAs(User::factory()->create(['role' => 'staff', 'has_access' => true]))->get('/dashboard')->assertOk()
            ->assertDontSee('All users', false)->assertDontSee(route('admin.users.index'));
    }

    public function test_orders_settings_and_help_pages_render(): void
    {
        $this->actingAs($this->admin());
        $this->get('/orders')->assertOk()->assertSee('Orders')->assertSee('Move to next stage');
        $this->get('/settings')->assertOk()->assertSee('Appearance')->assertSee('Yours only; your team picks their own');
        $this->get('/help')->assertOk()->assertSee('Keyboard shortcuts');
    }

    public function test_write_actions_need_the_app_database_and_csrf_protected_routes(): void
    {
        $this->actingAs($this->admin());
        // The test fixtures are not the app's database: nothing is pretended to be saved.
        $this->postJson('/orders/branch-calamba-0-0/advance', ['from' => 'completed'])->assertStatus(503);
        $this->postJson('/stock/receive', [])->assertStatus(503);
        $this->postJson('/orders', [])->assertStatus(503);
    }

    public function test_next_status_follows_the_app_workflow(): void
    {
        $this->assertSame('confirmed', AdminActions::nextStatus('pending', false));
        $this->assertSame('preparing', AdminActions::nextStatus('confirmed', false));
        $this->assertSame('readyForPickup', AdminActions::nextStatus('preparing', false));
        $this->assertSame('completed', AdminActions::nextStatus('readyForPickup', false));
        // Delivery orders never move on the website (handled in the app only), at any stage.
        foreach (['pending', 'confirmed', 'preparing', 'outForDelivery', 'readyForPickup'] as $status) {
            $this->assertNull(AdminActions::nextStatus($status, true), $status);
        }
        $this->assertNull(AdminActions::nextStatus('outForDelivery', false));
        $this->assertNull(AdminActions::nextStatus('completed', false));
        $this->assertNull(AdminActions::nextStatus('cancelled', false));
    }
}

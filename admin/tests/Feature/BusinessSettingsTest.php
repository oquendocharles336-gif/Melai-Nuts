<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Settings > Business settings: owner-editable rules stored in the app's database. Nothing is
 * invented: an empty field is "Not set", and pages show "No target set" / "Not rated" until the
 * owner sets a value. (The real SQL is tested in supabase/tests/business_settings_test.sql and in
 * SupabaseIntegrationTest.)
 */
class BusinessSettingsTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_nothing_set_is_shown_as_not_set_and_the_dashboard_invents_no_rating(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/admin/business-settings')->assertOk()
            ->assertSee('Business settings')->assertSee('Not set: customers earn no points yet')
            ->assertSee('Not set: points cannot be redeemed yet')->assertSee('Off (owner decision)', false)
            ->assertSee('Calamba Branch')->assertSee('Los Baños Branch');

        $page = $this->signedIn($owner)->get('/dashboard')->assertOk()->assertSee('No target set');
        foreach ($page->viewData('branches') as $b) {
            $this->assertNull($b['daily_target'], 'no target is invented');
        }
        foreach ($page->viewData('stock') as $s) {
            $this->assertContains($s['status'], ['unrated', 'none'], 'no stock rating without the owner\'s ratios');
        }
    }

    public function test_owner_saves_settings_and_the_dashboard_uses_them(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->put('/admin/business-settings', [
            'restock_threshold_default' => '12', 'stock_low_percent' => '40', 'stock_plenty_percent' => '80',
            'sales_low_percent' => '70', 'sales_high_percent' => '100', 'default_daily_sales_target' => '5000',
            'healthy_margin_percent' => '45', 'expiry_alert_days' => '14', 'low_stock_badge_qty' => '3',
        ])->assertRedirect(route('admin.business.index'));
        $this->assertSame(14, $this->db->settings['expiry_alert_days']);
        $this->assertSame(3, $this->db->settings['low_stock_badge_qty']);

        $this->assertEquals(['restock_threshold_default' => 12, 'stock_low_ratio' => 0.4, 'stock_plenty_ratio' => 0.8,
            'sales_low_ratio' => 0.7, 'sales_high_ratio' => 1.0, 'default_daily_sales_target' => 5000.0, 'healthy_margin_percent' => 45.0],
            array_intersect_key($this->db->settings, array_flip(['restock_threshold_default', 'stock_low_ratio', 'stock_plenty_ratio',
                'sales_low_ratio', 'sales_high_ratio', 'default_daily_sales_target', 'healthy_margin_percent'])));
        $this->assertContains('owner_update_business_settings', $this->db->calledFunctions('uid-owner'));

        $page = $this->signedIn($owner)->get('/dashboard?fresh=1')->assertOk()->assertSee('of ₱5,000 target', false);
        foreach ($page->viewData('branches') as $b) {
            $this->assertSame(5000.0, $b['daily_target']);
        }
        foreach ($page->viewData('stock') as $s) {
            $this->assertNotSame('unrated', $s['status']);
        }
    }

    public function test_an_empty_field_clears_the_setting(): void
    {
        $this->useFakeSupabase();
        $this->db->settings['default_daily_sales_target'] = 4000;
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->put('/admin/business-settings', ['default_daily_sales_target' => ''])->assertRedirect();
        $this->assertNull($this->db->settings['default_daily_sales_target']);
    }

    public function test_invalid_values_are_refused_before_reaching_the_database(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->put('/admin/business-settings', ['stock_low_percent' => '90', 'stock_plenty_percent' => '50'])
            ->assertSessionHasErrors('stock_low_percent');
        $this->signedIn($owner)->put('/admin/business-settings', ['healthy_margin_percent' => '150'])->assertSessionHasErrors('healthy_margin_percent');
        $this->signedIn($owner)->put('/admin/business-settings', ['restock_threshold_default' => '-1'])->assertSessionHasErrors('restock_threshold_default');
        $this->assertNotContains('owner_update_business_settings', $this->db->calledFunctions());
    }

    public function test_owner_adds_and_edits_a_branch_with_a_required_delivery_fee(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->post('/admin/branches', ['name' => 'New Branch', 'address' => 'Real street'])
            ->assertSessionHasErrors('delivery_fee');
        $this->signedIn($owner)->post('/admin/branches', ['name' => 'New Branch', 'address' => 'Real street', 'delivery_fee' => '0',
            'supports_pickup' => '1', 'is_active' => '1'])->assertRedirect(route('admin.business.index'));
        $new = collect($this->db->branches)->firstWhere('name', 'New Branch');
        $this->assertSame('Real street', $new['address']);
        $this->assertSame(0.0, $new['delivery_fee']);
        $this->assertFalse($new['supports_delivery']);

        $this->signedIn($owner)->put('/admin/branches/b-cal', ['name' => 'Calamba Branch', 'contact_phone' => '09170000000',
            'operating_hours' => '8-5', 'delivery_fee' => '35', 'daily_sales_target' => '6000', 'supports_delivery' => '1', 'is_active' => '1'])
            ->assertRedirect();
        $cal = collect($this->db->branches)->firstWhere('id', 'b-cal');
        $this->assertSame(['09170000000', '8-5', 35.0, 6000.0, true], [$cal['contact_phone'], $cal['operating_hours'], $cal['delivery_fee'], $cal['daily_sales_target'], $cal['supports_delivery']]);
    }

    public function test_staff_cannot_open_or_change_business_settings(): void
    {
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');

        $this->signedIn($staff)->get('/admin/business-settings')->assertForbidden();
        $this->signedIn($staff)->put('/admin/business-settings', ['restock_threshold_default' => '1'])->assertForbidden();
        $this->signedIn($staff)->post('/admin/branches', ['name' => 'X', 'delivery_fee' => '0'])->assertForbidden();
        $this->assertNotContains('owner_update_business_settings', $this->db->calledFunctions());
        $this->assertNotContains('owner_save_branch', $this->db->calledFunctions());
    }

    public function test_a_branch_marked_as_warehouse_sells_nothing(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->put('/admin/branches/b-lb', ['name' => 'Los Baños Branch', 'delivery_fee' => '0',
            'supports_delivery' => '1', 'supports_pickup' => '1', 'is_active' => '1', 'is_warehouse' => '1'])->assertRedirect();
        $lb = collect($this->db->branches)->firstWhere('id', 'b-lb');
        $this->assertTrue($lb['is_warehouse']);
        $this->assertFalse($lb['supports_delivery']);
        $this->assertFalse($lb['supports_pickup']);
        $this->assertContains('owner_set_branch_warehouse', $this->db->calledFunctions('uid-owner'));

        // Back to a shop: the warehouse flag is cleared first, then pickup can be offered again.
        $this->signedIn($owner)->put('/admin/branches/b-lb', ['name' => 'Los Baños Branch', 'delivery_fee' => '0',
            'supports_pickup' => '1', 'is_active' => '1'])->assertRedirect();
        $lb = collect($this->db->branches)->firstWhere('id', 'b-lb');
        $this->assertFalse($lb['is_warehouse']);
        $this->assertTrue($lb['supports_pickup']);
    }
}

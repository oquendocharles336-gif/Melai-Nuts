<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Owner: profit by product option and inventory valuation (real SQL is tested in
 * supabase/tests/owner_reports_test.sql). Options without a cost are "Not set", never zero.
 */
class ProfitReportTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function seedRows(): void
    {
        $this->db->profit['rows'] = [
            ['product' => 'Nut', 'variant' => 'Costed', 'net_units' => 3, 'net_sales' => 270, 'unit_cost' => 60, 'cogs' => 180, 'profit' => 90, 'margin_percent' => 33.3],
            ['product' => '=HYPERLINK("x")', 'variant' => 'NoCost', 'net_units' => 2, 'net_sales' => 200, 'unit_cost' => null, 'cogs' => null, 'profit' => null, 'margin_percent' => null],
        ];
        $this->db->profit['totals'] = ['net_sales' => 470, 'cogs' => 180, 'profit' => 90, 'margin_percent' => 33.3, 'options_without_cost' => 1, 'net_sales_without_cost' => 200];
        $this->db->valuation['rows'] = [['branch' => 'Shop', 'product' => 'Nut', 'variant' => 'Costed', 'quantity' => 10, 'unit_cost' => 60, 'value' => 600, 'is_warehouse' => false]];
        $this->db->valuation['totals'] = ['units' => 10, 'value' => 600, 'units_without_cost' => 0, 'options_without_cost' => 0];
    }

    public function test_owner_sees_profit_and_stock_value_with_uncosted_options_kept_apart(): void
    {
        $this->useFakeSupabase();
        $this->seedRows();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/admin/profit')->assertOk()
            ->assertSee('₱90.00')->assertSee('33.3% margin')->assertSee('₱600.00')
            ->assertSee('1 option(s) sold without a cost entered', false)
            ->assertSee('Not set')->assertSee('Print / Save as PDF')
            ->assertSee('current cost of each product option');
        $this->assertContains('owner_profit_report', $this->db->calledFunctions('uid-owner'));
    }

    public function test_empty_database_shows_honest_empty_states(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->get('/admin/profit')->assertOk()
            ->assertSee('No verified sales in this period.')->assertSee('No stock on hand.');
    }

    public function test_csv_export_is_formula_safe_and_states_the_cost_basis(): void
    {
        $this->useFakeSupabase();
        $this->seedRows();
        $owner = $this->linkedLogin('uid-owner');

        $csv = $this->signedIn($owner)->get('/admin/profit/export/profit?from=2026-10-01&to=2026-10-10')->assertOk()->streamedContent();
        $this->assertStringContainsString('# cost basis: current cost', $csv);
        $this->assertStringContainsString("product,variant,net_units,net_sales,unit_cost,cogs,profit,margin_percent", $csv);
        $this->assertStringContainsString("'=HYPERLINK", $csv);
        $this->assertStringContainsString('Nut,Costed,3,270,60,180,90,33.3', $csv);

        $this->signedIn($owner)->get('/admin/profit/export/valuation')->assertOk();
        $this->signedIn($owner)->get('/admin/profit/export/other')->assertNotFound();
    }

    public function test_branch_staff_cannot_open_it(): void
    {
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');
        $this->signedIn($staff)->get('/admin/profit')->assertForbidden();
        $this->signedIn($staff)->get('/admin/profit/export/profit')->assertForbidden();
    }
}

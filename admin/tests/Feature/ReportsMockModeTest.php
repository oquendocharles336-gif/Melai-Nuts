<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

/** Reports/forecast pages need the shared database; in demo mode they must not pretend. */
class ReportsMockModeTest extends TestCase
{
    use RefreshDatabase;

    public function test_forecast_and_export_are_not_available_in_demo_mode(): void
    {
        config(['melai.data_source' => 'mock']);
        $admin = User::factory()->create(['role' => 'admin', 'has_access' => true]);

        $this->actingAs($admin)->get('/reports/forecast')->assertNotFound();
        $this->actingAs($admin)->get('/reports/export')->assertNotFound();
        $this->actingAs($admin)->get('/s/reports')->assertOk()->assertSee('not connected here')->assertDontSee('₱');
    }

    public function test_guests_cannot_reach_reports(): void
    {
        config(['melai.data_source' => 'supabase']);
        $this->get('/reports/forecast')->assertRedirect('/login');
        $this->get('/reports/export')->assertRedirect('/login');
    }
}

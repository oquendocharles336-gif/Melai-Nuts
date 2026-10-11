<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * A brand-new project (schema.sql + migrations): no branches, products, stock, orders, rewards
 * or settings. Every page must load and say what is missing — never show invented figures.
 */
class EmptyDatabaseTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function emptyDatabase(): void
    {
        $this->useFakeSupabase();
        $this->db->branches = [];
        $this->db->orders = [];
        $this->db->stock = [];
        $this->db->customers = [];
        $this->db->drivers = [];
        $this->db->activity = [];
        $this->db->staff = ['uid-owner' => $this->db->staff['uid-owner']];
    }

    public function test_owner_pages_load_with_honest_empty_states(): void
    {
        $this->emptyDatabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/dashboard')->assertOk()->assertSee('No branches are available to this account.');
        $this->signedIn($owner)->get('/admin/business-settings')->assertOk()
            ->assertSee('No branches yet. Add the first one below')
            ->assertSee('Not set: customers earn no points yet');
        $this->signedIn($owner)->get('/orders')->assertOk();
        $this->signedIn($owner)->get('/loyalty')->assertOk()->assertSee('Not set: no loyalty rules have been saved yet');
    }

    public function test_no_invented_figures_on_the_dashboard(): void
    {
        $this->emptyDatabase();
        $owner = $this->linkedLogin('uid-owner');

        $page = $this->signedIn($owner)->get('/dashboard')->assertOk();
        $this->assertSame([], $page->viewData('sales'));
        $this->assertSame([], $page->viewData('stock'));
        foreach (['₱6,000', '₱5,000', '₱4,500', 'Calamba', 'Los Baños', 'Santa Cruz'] as $invented) {
            $page->assertDontSee($invented, false);
        }
    }
}

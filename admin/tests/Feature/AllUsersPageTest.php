<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeSupabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** /admin/users as the all-users view: website logins merged with every app account (owner only). */
class AllUsersPageTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function names($page): array
    {
        return collect($page->viewData('people')->items())->pluck('name')->all();
    }

    public function test_owner_sees_logins_staff_and_customers_in_one_list_but_no_riders(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        User::factory()->create(['name' => 'Wendy Website', 'email' => 'wendy@example.test', 'role' => 'staff', 'has_access' => true]);

        $page = $this->signedIn($owner)->get('/admin/users')->assertOk()
            ->assertSee('Melai Owner')->assertSee('Cora Cashier')->assertSee('Lito Cashier')
            ->assertSee('Carla Customer')->assertSee('Wendy Website')
            ->assertSee('App · Customer')->assertSee('Card CARD-0042')
            // Riders are app-only accounts: the database still returns them, the website never shows them.
            ->assertDontSee('Dario Rider')->assertDontSee('App · Driver')->assertDontSee('Tracking')
            ->assertSee('3 orders · ₱1,250.50 paid', false)->assertSee('25 pts');

        $this->assertContains('owner_all_users', $this->db->calledFunctions('uid-owner'));
        $this->assertSame(['all' => 5, 'attention' => 0, 'logins' => 2, 'team' => 3, 'customers' => 1], $page->viewData('counts'));
    }

    public function test_a_linked_login_and_its_app_account_are_one_person(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $people = collect($this->signedIn($owner)->get('/admin/users')->viewData('people')->items());
        $me = $people->where('email', 'owner@melainuts.test');
        $this->assertCount(1, $me, 'login + staff row of the same UID are merged');
        $this->assertSame(['logins', 'team'], $me->first()['types']);
        $this->assertSame('All branches', $me->first()['branch']);
    }

    public function test_type_chips_and_search_narrow_the_list(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        // There is no riders chip any more: an unknown type falls back to everyone, riders still excluded.
        $this->assertNotContains('Dario Rider', $this->names($this->signedIn($owner)->get('/admin/users?type=drivers')->assertOk()));
        $this->assertSame(['Carla Customer'], $this->names($this->signedIn($owner)->get('/admin/users?type=customers')));
        $this->assertSame(['Melai Owner'], $this->names($this->signedIn($owner)->get('/admin/users?type=logins')));
        $this->assertSame(['Melai Owner', 'Cora Cashier', 'Lito Cashier'], $this->names($this->signedIn($owner)->get('/admin/users?type=team')));

        // Search reaches customers in the database (card number) and everyone else in PHP (branch name).
        $this->assertSame(['Carla Customer'], $this->names($this->signedIn($owner)->get('/admin/users?q=card-0042')));
        $this->assertSame('card-0042', collect($this->db->calls)->where('fn', 'owner_all_users')->last()['bindings'][0]);
        $this->assertSame(['Cora Cashier'], $this->names($this->signedIn($owner)->get('/admin/users?q=calamba')));
        $this->signedIn($owner)->get('/admin/users?q=nobody-at-all')->assertOk()->assertSee('No one matches');

        // An unknown type falls back to everyone.
        $this->assertSame('all', $this->signedIn($owner)->get('/admin/users?type=../../etc')->viewData('type'));
    }

    public function test_pending_registrations_are_flagged_and_listed_first(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $reg = User::factory()->create(['name' => 'Zed Newcomer', 'email' => 'zed@example.test', 'role' => 'staff', 'has_access' => false]);
        $reg->forceFill(['firebase_uid' => 'uid-zed', 'firebase_email_verified' => true])->save();

        $page = $this->signedIn($owner)->get('/admin/users')->assertOk()->assertSee('Needs approval')->assertSee('Approve');
        $this->assertSame('Zed Newcomer', $this->names($page)[0]);
        $this->assertSame(1, $page->viewData('counts')['attention']);
        $this->assertSame(['Zed Newcomer'], $this->names($this->signedIn($owner)->get('/admin/users?type=attention')));
    }

    public function test_inactive_app_accounts_show_their_status(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->db->staff['uid-lb']['account_status'] = 'suspended';

        $this->signedIn($owner)->get('/admin/users')->assertOk()->assertSee('App suspended');
    }

    public function test_capped_customer_list_says_so(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        foreach (range(1, 3) as $i) {
            $this->db->customers["uid-c$i"] = ['firebase_uid' => "uid-c$i", 'full_name' => "Extra Customer $i", 'email' => "c$i@example.test", 'phone' => null,
                'card_number' => null, 'branch_id' => null, 'created_at' => now()->toIso8601String(), 'orders' => 0, 'paid_total' => 0, 'last_order_at' => null, 'points_balance' => null];
        }
        config(['melai.users_customer_limit' => 2]);

        $page = $this->signedIn($owner)->get('/admin/users?type=customers')->assertOk()->assertSee('Showing the newest 2 of 4 customers');
        $this->assertCount(2, $page->viewData('people')->items());
        $this->assertSame(2, collect($this->db->calls)->firstWhere('fn', 'owner_all_users')['bindings'][1]);

        config(['melai.users_customer_limit' => 500]);
        $this->signedIn($owner)->get('/admin/users?type=customers')->assertOk()->assertDontSee('Showing the newest');
    }

    public function test_older_database_without_the_migration_still_lists_everyone_it_can(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->db->missing = ['owner_all_users'];

        $page = $this->signedIn($owner)->get('/admin/users')->assertOk()
            ->assertSee('missing migration 20261014000000', false)
            ->assertSee('Cora Cashier')->assertSee('Carla Customer')->assertSee('Orders unknown');
        $this->assertTrue($page->viewData('partial'));
        $this->assertContains('admin_portal_staff_directory', $this->db->calledFunctions('uid-owner'));
        $this->assertContains('admin_portal_loyalty_members', $this->db->calledFunctions('uid-owner'));
    }

    public function test_database_down_still_shows_website_logins(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->db->offline = true;

        $page = $this->signedIn($owner)->get('/admin/users')->assertOk()->assertSee('Could not load the app')->assertSee('Melai Owner');
        $this->assertFalse($page->viewData('appLoaded'));
        $this->assertSame(1, $page->viewData('counts')['all']);
    }

    public function test_admin_login_linked_to_a_staff_account_gets_no_app_accounts(): void
    {
        // The website role says admin but the app account is staff: owner_all_users refuses, nothing leaks.
        $this->useFakeSupabase();
        $u = $this->linkedLogin('uid-cal');
        $u->forceFill(['role' => 'admin'])->save();

        $this->signedIn($u)->get('/admin/users')->assertOk()->assertSee('Could not load the app')
            ->assertDontSee('Carla Customer')->assertDontSee('Dario Rider')->assertDontSee('Lito Cashier');
    }

    public function test_staff_cannot_open_the_page(): void
    {
        $this->useFakeSupabase();
        $this->signedIn($this->linkedLogin('uid-cal'))->get('/admin/users')->assertForbidden();
        $this->assertNotContains('owner_all_users', $this->db->calledFunctions());
    }

    public function test_mock_mode_lists_website_logins_only(): void
    {
        $admin = User::factory()->create(['name' => 'Ada Admin', 'role' => 'admin', 'has_access' => true]);
        User::factory()->create(['name' => 'Ben Waiting', 'role' => 'staff', 'has_access' => false]);

        $page = $this->actingAs($admin)->get('/admin/users')->assertOk()->assertSee('Ada Admin')->assertSee('Ben Waiting')
            ->assertSee('Waiting for access')->assertDontSee('Customers <span', false);
        $this->assertSame('Ben Waiting', $this->names($page)[0], 'waiting logins first');
    }

    public function test_many_people_are_paginated(): void
    {
        $admin = User::factory()->create(['role' => 'admin', 'has_access' => true]);
        User::factory()->count(60)->create(['role' => 'staff', 'has_access' => true]);

        $first = $this->actingAs($admin)->get('/admin/users')->assertOk();
        $this->assertCount(50, $first->viewData('people')->items());
        $this->assertCount(11, $this->actingAs($admin)->get('/admin/users?page=2')->viewData('people')->items());
    }
}

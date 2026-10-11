<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Who may reach the money pages. These checks run before any data is read, so they need no
 * database. What the pages do with real data is covered end to end in SupabaseIntegrationTest
 * (cash payment confirmation, refund approve / reject / complete / HitPay, loyalty settings
 * and adjustments).
 */
class AccessControlTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function staff(): User
    {
        return User::factory()->create(['role' => 'staff', 'has_access' => true]);
    }

    public function test_staff_cannot_reach_payments_or_refunds(): void
    {
        $staff = $this->staff();
        $this->actingAs($staff)->get('/admin/payments')->assertForbidden();
        $this->actingAs($staff)->post('/admin/payments/ORD-1/mark-paid')->assertForbidden();
        $this->actingAs($staff)->get('/admin/refunds')->assertForbidden();
        $this->actingAs($staff)->post('/admin/refunds/ORD-1/approve')->assertForbidden();
        $this->actingAs($staff)->post('/admin/refunds/ORD-1/reject', ['reason' => 'x'])->assertForbidden();
    }

    public function test_staff_cannot_change_loyalty_settings_or_points(): void
    {
        $staff = $this->staff();
        $this->actingAs($staff)->put(route('admin.loyalty.settings.update'), ['earn_pesos_per_point' => 50])->assertForbidden();
        $this->actingAs($staff)->post(route('admin.loyalty.adjust', 'someone'), ['points' => 10, 'reason' => 'Goodwill'])->assertForbidden();
    }

    public function test_guests_are_sent_to_login(): void
    {
        $this->get('/admin/payments')->assertRedirect(route('login'));
        $this->get('/admin/refunds')->assertRedirect(route('login'));
        $this->get('/loyalty')->assertRedirect(route('login'));
    }

    public function test_removed_paymongo_endpoints_are_gone(): void
    {
        $this->post('/webhooks/paymongo')->assertNotFound();
        $admin = User::factory()->create(['role' => 'admin', 'has_access' => true]);
        $this->actingAs($admin)->post('/admin/refunds/ORD-1/retry')->assertNotFound();
    }

    // ---- branch scope: only app OWNERS get every branch and every staff account ----------------

    public function test_staff_login_never_sees_other_branches_or_the_staff_directory(): void
    {
        $this->useFakeSupabase();
        $cora = $this->linkedLogin('uid-cal');

        foreach (['/dashboard', '/dashboard?branch=b-lb', '/dashboard?period=month&branch=b-lb'] as $url) {
            $page = $this->signedIn($cora)->get($url)->assertOk()
                ->assertSee('Calamba Branch')->assertDontSee('Los Baños Branch')->assertDontSee('Staff accounts')->assertDontSee('Lito Cashier');
            $this->assertSame(['b-cal'], array_column($page->viewData('sales'), 'id'));
            $this->assertNull($page->viewData('staff'));
            $this->assertNull($page->viewData('branchId'), 'a branch outside the account is ignored');
            $this->assertEqualsWithDelta(700, $page->viewData('kpis')['net_sales'], 0.001);
        }
        $this->signedIn($cora)->get('/s/cash-drawer?branch=b-lb')->assertOk()->assertDontSee('Los Baños Branch')->assertDontSee('All branches');

        $this->assertNotContains('owner_staff_overview', $this->db->calledFunctions('uid-cal'));
        $this->assertSame(['b-cal'], collect($this->db->calls)->where('fn', 'staff_cashier_daily_summary')->pluck('bindings.0')->unique()->values()->all());
        $this->assertEmpty(array_diff(array_unique(array_column($this->db->calls, 'uid')), ['uid-cal']), 'every query ran as the verified UID');
    }

    public function test_website_admin_role_alone_does_not_unlock_the_all_branch_view(): void
    {
        // Even if the website's role column says admin, the app account is staff: still one branch, no directory.
        $this->useFakeSupabase();
        $u = $this->linkedLogin('uid-cal');
        $u->forceFill(['role' => 'admin'])->save();

        $page = $this->signedIn($u)->get('/dashboard')->assertOk()->assertDontSee('Los Baños Branch');
        $this->assertFalse($page->viewData('isOwner'));
        $this->assertNull($page->viewData('staff'));
    }

    public function test_owner_gets_every_branch_and_can_narrow_to_one(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $all = $this->signedIn($owner)->get('/dashboard')->assertOk()->assertSee('Los Baños Branch')->assertSee('Lito Cashier');
        $this->assertSame(['b-cal', 'b-lb'], array_column($all->viewData('sales'), 'id'));
        $this->assertCount(3, $all->viewData('staff'));

        $one = $this->signedIn($owner)->get('/dashboard?branch=b-lb')->assertOk();
        $this->assertSame(['b-lb'], array_column($one->viewData('sales'), 'id'));
        $this->assertSame(['uid-lb'], array_column($one->viewData('staff'), 'firebase_uid'));
        $this->assertEqualsWithDelta(450, $one->viewData('kpis')['net_sales'], 0.001);

        $this->signedIn($owner)->get('/s/cash-drawer')->assertOk()->assertSee('All branches added up');
        $this->assertSame(['b-cal', 'b-lb'], collect($this->db->calls)->where('fn', 'staff_cashier_daily_summary')->pluck('bindings.0')->values()->all());
    }

    public function test_uid_never_comes_from_the_request(): void
    {
        $this->useFakeSupabase();
        $cora = $this->linkedLogin('uid-cal');
        $this->signedIn($cora)->get('/dashboard?uid=uid-owner&staff_uid=uid-owner&firebase_uid=uid-owner')->assertOk()->assertDontSee('Los Baños Branch');
        $this->assertNotContains('uid-owner', array_column($this->db->calls, 'uid'));
    }

    public function test_staff_signed_in_with_the_website_password_is_still_limited_to_their_branch(): void
    {
        $this->useFakeSupabase();
        $lito = User::factory()->create(['email' => 'lito@melainuts.test', 'password' => 'Lito#Pass1', 'role' => 'staff', 'has_access' => true]);
        $this->post('/login', ['email' => 'lito@melainuts.test', 'password' => 'Lito#Pass1'])->assertRedirect(route('dashboard'));

        $page = $this->get('/dashboard?branch=b-cal')->assertOk()->assertSee('Los Baños Branch')->assertDontSee('Calamba Branch')->assertDontSee('Staff accounts');
        $this->assertSame(['b-lb'], array_column($page->viewData('sales'), 'id'));
        $this->assertNotContains('owner_staff_overview', $this->db->calledFunctions('uid-lb'));
        $this->assertNotContains('uid-owner', array_column($this->db->calls, 'uid'));
    }
}

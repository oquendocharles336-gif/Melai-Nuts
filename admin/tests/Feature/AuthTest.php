<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeFirebase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

class AuthTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    protected function setUp(): void
    {
        parent::setUp();
        // Sign-in always asks Firebase first; these accounts do not exist there (fake, no network).
        $this->fb = (new FakeFirebase)->install();
    }

    private function reg(array $o = []): array
    {
        return array_merge(['name' => 'Juan Dela Cruz', 'email' => 'juan@example.com',
            'password' => 'Str0ng!Pass', 'password_confirmation' => 'Str0ng!Pass', 'terms' => '1'], $o);
    }

    private function admin(): User { return User::factory()->create(['role' => 'admin', 'has_access' => true]); }
    private function staff(): User { return User::factory()->create(['role' => 'staff', 'has_access' => false]); }

    public function test_landing_shows_welcome_admin(): void
    {
        $this->get('/')->assertOk()->assertSee('WELCOME ADMIN');
    }

    public function test_empty_fields(): void
    {
        $this->post('/login', [])->assertSessionHasErrors(['email', 'password']);
        $this->post('/register', [])->assertSessionHasErrors(['name', 'email', 'password', 'password_confirmation']);
    }

    public function test_invalid_email(): void
    {
        $this->post('/register', $this->reg(['email' => 'not-an-email']))->assertSessionHasErrors('email');
        $this->post('/login', ['email' => 'nope', 'password' => 'x'])->assertSessionHasErrors('email');
    }

    public function test_duplicate_email_is_case_insensitive(): void
    {
        User::factory()->create(['email' => 'juan@example.com']);
        $this->post('/register', $this->reg(['email' => '  JUAN@Example.com ']))->assertSessionHasErrors('email');
    }

    public function test_weak_passwords_rejected(): void
    {
        foreach (['Ab1!', 'alllowercase1!', 'ALLUPPERCASE1!', 'NoNumbers!!Aa', 'NoSymbols123Aa'] as $pw) {
            $this->post('/register', $this->reg(['password' => $pw, 'password_confirmation' => $pw]))
                ->assertSessionHasErrors('password');
        }
    }

    public function test_mismatched_passwords(): void
    {
        $this->post('/register', $this->reg(['password_confirmation' => 'Different1!']))
            ->assertSessionHasErrors('password_confirmation');
    }

    public function test_registration_is_refused_with_the_exact_missing_firebase_setting(): void
    {
        // phpunit.xml sets FIREBASE_WEB_API_KEY but no FIREBASE_PROJECT_ID; then also drop the key.
        config(['services.firebase.web_api_key' => null, 'services.firebase.project_id' => null]);
        $this->post('/register', $this->reg())->assertSessionHasErrors('auth');
        $msg = session('errors')->first('auth');
        $this->assertStringContainsString('FIREBASE_WEB_API_KEY', $msg);
        $this->assertStringContainsString('FIREBASE_PROJECT_ID', $msg);
        $this->assertStringContainsString('Web API key', $msg);
        $this->assertGuest();
        $this->assertDatabaseMissing('users', ['email' => 'juan@example.com']);
    }

    public function test_new_account_only_sees_waiting_page(): void
    {
        $this->actingAs($this->staff());
        $this->get('/waiting')->assertOk()->assertSee('Waiting for admin access');
        $this->get('/dashboard')->assertRedirect(route('waiting'));
    }

    public function test_staff_gets_403_on_admin_pages(): void
    {
        $this->actingAs($this->staff())->get('/admin/activity-logs')->assertForbidden();
    }

    public function test_admin_reaches_dashboard_and_logs(): void
    {
        $this->actingAs($this->admin());
        $this->get('/dashboard')->assertOk();
        $this->get('/admin/activity-logs')->assertOk();
    }

    public function test_wrong_credentials_use_generic_message(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass']);
        $generic = 'Invalid email or password. Use your Melai Nuts app email and password.';
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'wrong'])
            ->assertSessionHasErrors(['auth' => $generic]);
        $this->post('/login', ['email' => 'nobody@example.com', 'password' => 'wrong'])
            ->assertSessionHasErrors(['auth' => $generic]);
    }

    public function test_lockout_after_five_attempts(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass']);
        for ($i = 0; $i < 5; $i++) {
            $this->post('/login', ['email' => 'a@example.com', 'password' => 'wrong']);
        }
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass']);
        $this->assertGuest();
        $this->assertStringContainsString('Too many login attempts', session('errors')->first('auth'));
    }

    public function test_login_success_logs_activity(): void
    {
        $u = User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'has_access' => true]);
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass'])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($u);
        $this->assertTrue(ActivityLog::where('action', 'auth.login')->exists());
    }

    public function test_deactivated_user_cannot_login(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'is_active' => false]);
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass'])->assertSessionHasErrors('auth');
        $this->assertGuest();
    }

    public function test_guests_are_redirected_and_logged_in_users_are_kept_out_of_login(): void
    {
        $this->get('/dashboard')->assertRedirect(route('login'));
        $this->get('/admin/activity-logs')->assertRedirect(route('login'));
        $this->actingAs($this->admin())->get('/login')->assertRedirect(route('dashboard'));
        $this->get('/register')->assertRedirect(route('dashboard'));
    }

    public function test_logout_invalidates_session(): void
    {
        $this->actingAs($this->admin())->post('/logout')->assertRedirect(route('landing'));
        $this->assertGuest();
        $this->get('/dashboard')->assertRedirect(route('login'));
    }

    // ---- automatic link at sign-in (DATA_SOURCE=supabase, FakeSupabase + FakeFirebase) -------------

    public function test_owner_signs_in_and_lands_on_the_all_branch_dashboard_with_no_link_step(): void
    {
        $this->useFakeSupabase();
        // The seeded "Melai Admin" (AdminSeeder): local password, no Firebase identity, no staff_uid yet.
        $admin = User::factory()->create(['name' => 'Melai Admin', 'email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1', 'role' => 'admin', 'has_access' => true]);

        $this->post('/login', ['email' => 'OWNER@melainuts.test', 'password' => 'uid-owner#Pass1'])
            ->assertRedirect(route('dashboard'))->assertSessionHasNoErrors();

        $admin = $admin->fresh();
        $this->assertAuthenticatedAs($admin);
        $this->assertSame('uid-owner', $admin->firebase_uid, 'bound to the owner\'s Firebase account by e-mail');
        $this->assertSame('uid-owner', $admin->staff_uid, 'linked to the owner row in staff_members');
        foreach (['account.firebase_bound', 'account.staff_linked', 'account.auto_linked', 'auth.login'] as $action) {
            $this->assertTrue(ActivityLog::where('action', $action)->exists(), "$action logged");
        }
        $this->assertFalse(ActivityLog::all()->contains(fn ($l) => str_contains(json_encode($l->meta).$l->description, 'uid-owner#Pass1')), 'password never stored');
        $this->assertNotContains('get_my_staff_context', array_column(array_filter($this->db->calls, fn ($c) => $c['uid'] !== 'uid-owner'), 'fn'), 'only the verified UID is used');

        $page = $this->get('/dashboard')->assertOk()
            ->assertSee('Calamba Branch')->assertSee('Los Baños Branch')->assertSee('All branches')
            ->assertSee('Staff accounts')->assertSee('Cora Cashier')->assertSee('Lito Cashier')
            ->assertDontSee('Account not linked')->assertDontSee('Link my app account');
        $this->assertEqualsWithDelta(1150, $page->viewData('kpis')['net_sales'], 0.001); // both branches' paid orders
        $this->assertSame('uid-cal', $page->viewData('topStaff')[0]['firebase_uid']);
        $this->assertSame('Calamba Branch', $page->viewData('topBranches')[0]['name']);
    }

    public function test_first_sign_in_without_a_website_login_creates_and_links_it(): void
    {
        $this->useFakeSupabase();
        $this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'uid-cal#Pass1'])->assertRedirect(route('dashboard'));

        $u = User::firstWhere('email', 'cora@melainuts.test');
        $this->assertSame(['staff', 'uid-cal', 'uid-cal', true], [$u->role, $u->firebase_uid, $u->staff_uid, $u->has_access]);
    }

    public function test_melai_admin_signs_in_with_the_website_password_and_acts_as_the_owner_via_admin_staff_uid(): void
    {
        $this->useFakeSupabase();
        config(['melai.admin.email' => 'owner@melainuts.test', 'melai.admin.staff_uid' => 'uid-owner']);
        // The seeded "Melai Admin": website password only, no Firebase identity, staff_uid still empty.
        $admin = User::factory()->create(['name' => 'Melai Admin', 'email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1', 'role' => 'admin', 'has_access' => true]);

        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1'])
            ->assertRedirect(route('dashboard'))->assertSessionHasNoErrors();
        $this->assertAuthenticatedAs($admin->fresh());
        $this->assertSame('uid-owner', $admin->fresh()->staff_uid);
        $this->assertNull($admin->fresh()->firebase_uid, 'no second app sign-in needed');
        $this->assertTrue(ActivityLog::where('action', 'account.auto_linked')->where('meta->source', 'ADMIN_STAFF_UID')->exists());
        $this->assertTrue(ActivityLog::where('action', 'auth.login')->where('meta->method', 'local')->exists());

        $page = $this->get('/dashboard')->assertOk()
            ->assertSee('Calamba Branch')->assertSee('Los Baños Branch')->assertSee('Cora Cashier')->assertSee('Lito Cashier')
            ->assertDontSee('Account not linked')->assertDontSee('Link my app account');
        $this->assertEqualsWithDelta(1150, $page->viewData('kpis')['net_sales'], 0.001);
        $this->assertNotContains(null, array_column(array_filter($this->db->calls, fn ($c) => $c['fn'] !== 'portal_staff_uid_for_email'), 'uid'));
        $this->assertSame(['uid-owner'], array_values(array_unique(array_filter(array_column($this->db->calls, 'uid')))), 'every query ran AS the owner');
    }

    public function test_first_sign_in_without_admin_staff_uid_links_by_the_owner_email_and_repairs_a_stale_link(): void
    {
        $this->useFakeSupabase();
        config(['melai.admin.staff_uid' => null]);
        $admin = User::factory()->create(['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1', 'role' => 'admin', 'has_access' => true]);
        $admin->forceFill(['staff_uid' => 'uid-gone'])->save(); // an old link to a row that no longer exists

        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertSame('uid-owner', $admin->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'account.staff_unlinked')->exists());
        $this->assertTrue(ActivityLog::where('action', 'account.auto_linked')->where('meta->source', 'email')->exists());
    }

    public function test_staff_website_login_is_matched_by_email_and_works_without_firebase(): void
    {
        $this->useFakeSupabase();
        config(['services.firebase.web_api_key' => null]); // Firebase not configured: website passwords still work
        $cora = User::factory()->create(['email' => 'cora@melainuts.test', 'password' => 'Cora#Pass1', 'role' => 'staff', 'has_access' => true]);

        $this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'Cora#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertSame('uid-cal', $cora->fresh()->staff_uid);
        $this->get('/dashboard')->assertOk()->assertSee('Calamba Branch')->assertDontSee('Los Baños Branch')->assertDontSee('Staff accounts');
    }

    public function test_no_matching_owner_or_staff_row_or_an_inactive_one_fails_on_the_login_page(): void
    {
        $this->useFakeSupabase();
        config(['melai.admin.staff_uid' => null]);
        User::factory()->create(['email' => 'nobody@melainuts.test', 'password' => 'Nobody#Pass1', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'nobody@melainuts.test', 'password' => 'Nobody#Pass1'])->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->assertStringContainsString('No active owner in the app\'s staff registry (staff_members) has the email nobody@melainuts.test', session('errors')->first('auth'));
        $this->assertStringContainsString('ADMIN_STAFF_UID', session('errors')->first('auth'));

        // ADMIN_STAFF_UID pointing at a STAFF row: refused with that reason.
        config(['melai.admin.staff_uid' => 'uid-cal']);
        $this->post('/login', ['email' => 'nobody@melainuts.test', 'password' => 'Nobody#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('does not match this login', session('errors')->first('auth'));

        // An owner deactivated in the app.
        config(['melai.admin.staff_uid' => 'uid-owner']);
        $this->db->staff['uid-owner']['account_status'] = 'inactive';
        User::factory()->create(['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('deactivated', session('errors')->first('auth'));
        $this->assertGuest();
        $this->assertTrue(ActivityLog::where('action', 'auth.autolink_failed')->exists());
    }

    public function test_admin_staff_uid_works_even_before_the_email_lookup_function_exists(): void
    {
        $this->useFakeSupabase();
        $this->db->missing = ['portal_staff_uid_for_email'];
        config(['melai.admin.staff_uid' => 'uid-owner']);
        $admin = User::factory()->create(['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertSame('uid-owner', $admin->fresh()->staff_uid);
        $this->assertNotContains('portal_staff_uid_for_email', array_column($this->db->calls, 'fn'), 'not needed when ADMIN_STAFF_UID checks out');
        $this->post('/logout');

        // Without ADMIN_STAFF_UID the reason names the missing migration.
        config(['melai.admin.staff_uid' => null]);
        $admin->forceFill(['staff_uid' => null])->save();
        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'Seed#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('20261013000000_admin_portal_owner_overview.sql', session('errors')->first('auth'));
    }

    public function test_deactivated_mid_session_is_sent_to_the_login_page_with_the_reason(): void
    {
        $this->useFakeSupabase();
        $admin = User::factory()->create(['email' => 'owner@melainuts.test', 'role' => 'admin', 'has_access' => true]);
        $admin->forceFill(['staff_uid' => 'uid-owner'])->save();
        $this->actingAs($admin)->get('/dashboard')->assertOk();

        $this->db->staff['uid-owner']['account_status'] = 'suspended';
        $this->actingAs($admin)->get('/dashboard')->assertRedirect(route('login'));
        $this->assertGuest();
        $this->assertStringContainsString('suspended', session('errors')->first('auth'));
    }

    public function test_wrong_password_and_missing_staff_row_fail_on_the_login_page_with_a_precise_message(): void
    {
        $this->useFakeSupabase();

        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'wrong'])
            ->assertSessionHasErrors(['auth' => 'Invalid email or password. Use your Melai Nuts app email and password.']);
        $this->assertGuest();

        // Real Firebase account, existing admin login, but no staff_members row for it.
        $this->fb->addAccount('ghost@melainuts.test', 'uid-ghost', 'Ghost#Pass1', true);
        $ghost = User::factory()->create(['email' => 'ghost@melainuts.test', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'ghost@melainuts.test', 'password' => 'Ghost#Pass1'])->assertSessionHasErrors('auth');
        $this->assertGuest();
        $msg = session('errors')->first('auth');
        $this->assertStringContainsString('App profile missing', $msg);
        $this->assertStringContainsString('staff_members', $msg);
        $this->assertNull($ghost->fresh()->staff_uid);
        $this->assertTrue(ActivityLog::where('action', 'auth.autolink_failed')->exists());

        // Owner role missing: an admin login whose app account is staff.
        $staffAsAdmin = User::factory()->create(['email' => 'lito@melainuts.test', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'lito@melainuts.test', 'password' => 'uid-lb#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('Admin logins need an owner account', session('errors')->first('auth'));
        $this->assertNull($staffAsAdmin->fresh()->staff_uid);
        $this->assertGuest();

        // Database unreachable: nothing is linked and the reason is shown.
        $this->db->offline = true;
        $this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'uid-cal#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('could not be reached', session('errors')->first('auth'));
        $this->assertGuest();
    }

    public function test_expired_token_is_refreshed_silently_and_a_dead_session_goes_back_to_login(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner, expiresIn: 30)->get('/dashboard')->assertOk()->assertSee('Calamba Branch');
        $this->assertGreaterThan(time() + 600, session('firebase_auth')['expires_at'], 'new ID token stored');

        $this->fb->set('uid-owner', 'revoked', true);
        $this->signedIn($owner, expiresIn: 30)->get('/dashboard')->assertRedirect(route('login'))->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->assertStringContainsString('Please sign in again', session('errors')->first('auth'));
        $this->get('/login')->assertOk()->assertSee('Please sign in again')->assertDontSee('Account not linked');
    }

    public function test_the_old_link_page_is_gone(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->get('/account/link')->assertRedirect('/dashboard');
        $this->signedIn($owner)->post('/account/link', ['app_email' => 'x@y.z', 'app_password' => 'p'])->assertRedirect(route('dashboard'));
        $this->signedIn($owner)->get('/dashboard')->assertOk()->assertDontSee('App account</a>', false);
    }
}

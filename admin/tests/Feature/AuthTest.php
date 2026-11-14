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
    /** A staff login left in the users table (old registration / old staff login): it can no longer use the website. */
    private function staff(): User { return User::factory()->create(['role' => 'staff', 'has_access' => true]); }

    public function test_home_is_the_shop_and_the_only_way_in_is_the_header_sign_in_button(): void
    {
        // "/" is the shop. Its header "Sign in" opens the sign-in panel; there is no other sign-in link.
        $home = $this->get('/')->assertOk()->assertSee('the slow way.')
            ->assertSee('data-panel-open="sign-in"', false)->assertSee('data-auth-panel', false)
            ->assertDontSee('Staff and owners: sign in')->assertDontSee('Staff sign in')->assertDontSee('data-start-open', false);
        $this->assertSame(1, substr_count($home->getContent(), 'class="s-signin"'), 'one sign-in button, in the header');
        // There is no separate sign-in page: /login opens the panel on the homepage.
        $this->get('/login')->assertRedirect('/?panel=sign-in');
        $this->get('/?panel=sign-in')->assertOk()->assertSee('data-start-open', false)->assertSee('Welcome back')
            ->assertSee('action="'.route('login').'"', false)->assertDontSee('Administration portal', false);
    }

    public function test_every_old_sign_in_address_opens_its_panel(): void
    {
        $this->get('/login')->assertRedirect('/?panel=sign-in');
        $this->get('/shop/login')->assertRedirect('/?panel=sign-in');
        $this->get('/register')->assertNotFound();   // no staff sign-up on the website
        $this->get('/shop/register')->assertRedirect('/?panel=create-account');
        $this->get('/forgot-password')->assertRedirect('/?panel=reset-password');
        $this->get('/shop/forgot-password')->assertRedirect('/?panel=reset-password');
        foreach (['sign-in' => 'Welcome back', 'create-account' => 'Create your account', 'reset-password' => 'Reset your password'] as $panel => $title) {
            $page = $this->get('/?panel='.$panel)->assertOk()->assertSee('data-shown="'.$panel.'"', false)->assertSee($title);
            $this->assertMatchesRegularExpression('/data-panel="'.$panel.'"\s+aria-labelledby/', $page->getContent(), $panel.' is the visible one');
        }
        $this->get('/?panel=staff-access')->assertOk()->assertDontSee('data-start-open', false)->assertDontSee('Request staff access');
        $this->get('/?panel=nonsense')->assertOk()->assertDontSee('data-start-open', false);
    }

    public function test_a_wrong_password_shows_inside_the_sign_in_panel(): void
    {
        $this->from('/?panel=sign-in')->post('/login', ['_panel' => 'sign-in', 'email' => 'nobody@example.com', 'password' => 'Wrong#Pass1'])
            ->assertRedirect('/?panel=sign-in')->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->get('/?panel=sign-in')->assertOk()->assertSee('Invalid email or password')
            ->assertSee('value="nobody@example.com"', false)->assertDontSee('Wrong#Pass1');
        // Empty fields come back to the panel too, with the message under the field.
        $this->post('/login', ['_panel' => 'sign-in'])->assertRedirect('/?panel=sign-in')->assertSessionHasErrors(['email', 'password']);
        $this->get('/')->assertOk()->assertSee('data-start-open', false)->assertSee('Email is required.');
    }

    public function test_signed_in_people_never_see_the_panel(): void
    {
        $this->actingAs($this->admin())->get('/?panel=sign-in')->assertOk()->assertDontSee('data-auth-panel', false)->assertSee('Back to dashboard');
    }

    public function test_empty_fields(): void
    {
        $this->post('/login', [])->assertSessionHasErrors(['email', 'password']);
    }

    public function test_invalid_email(): void
    {
        $this->post('/login', ['email' => 'nope', 'password' => 'x'])->assertSessionHasErrors('email');
    }

    public function test_there_is_no_staff_registration_on_the_website(): void
    {
        // Staff accounts are created by the owner (Users > Create account, or the app's User Management)
        // and sign in to the Melai Nuts app only. Nobody can register for the admin website.
        $this->get('/register')->assertNotFound();
        $this->post('/register', $this->reg())->assertNotFound();
        $this->post('/register', $this->reg(['role' => 'admin', 'has_access' => 1]))->assertNotFound();
        $this->assertGuest();
        $this->assertDatabaseMissing('users', ['email' => 'juan@example.com']);
        $this->assertSame([], $this->fb->accounts, 'no Firebase account was created');
    }

    public function test_owner_login_without_access_only_sees_the_waiting_page(): void
    {
        $this->actingAs(User::factory()->create(['role' => 'admin', 'has_access' => false]));
        $this->get('/waiting')->assertOk()->assertSee('Waiting for admin access');
        $this->get('/dashboard')->assertRedirect(route('waiting'));
    }

    public function test_staff_login_is_signed_out_on_every_page(): void
    {
        foreach (['/dashboard', '/waiting', '/settings', '/orders', '/admin/activity-logs', '/admin/users'] as $url) {
            $this->assertStaffKeptOut($this->actingAs($this->staff())->get($url));
        }
    }

    public function test_admin_reaches_dashboard_and_logs(): void
    {
        $this->actingAs($this->admin());
        $this->get('/dashboard')->assertOk();
        $this->get('/admin/activity-logs')->assertOk();
    }

    public function test_wrong_credentials_use_generic_message(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'role' => 'admin']);
        $generic = 'Invalid email or password. Use your Melai Nuts app email and password.';
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'wrong'])
            ->assertSessionHasErrors(['auth' => $generic]);
        $this->post('/login', ['email' => 'nobody@example.com', 'password' => 'wrong'])
            ->assertSessionHasErrors(['auth' => $generic]);
    }

    public function test_lockout_after_five_attempts(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'role' => 'admin']);
        for ($i = 0; $i < 5; $i++) {
            $this->post('/login', ['email' => 'a@example.com', 'password' => 'wrong']);
        }
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass']);
        $this->assertGuest();
        $this->assertStringContainsString('Too many login attempts', session('errors')->first('auth'));
    }

    public function test_login_success_logs_activity(): void
    {
        $u = User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass'])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($u);
        $this->assertTrue(ActivityLog::where('action', 'auth.login')->exists());
    }

    public function test_deactivated_user_cannot_login(): void
    {
        User::factory()->create(['email' => 'a@example.com', 'password' => 'Str0ng!Pass', 'role' => 'admin', 'is_active' => false]);
        $this->post('/login', ['email' => 'a@example.com', 'password' => 'Str0ng!Pass'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('deactivated', session('errors')->first('auth'));
        $this->assertGuest();
    }

    public function test_guests_are_redirected_and_logged_in_users_are_kept_out_of_login(): void
    {
        $this->get('/dashboard')->assertRedirect(route('login'));
        $this->get('/admin/activity-logs')->assertRedirect(route('login'));
        $this->actingAs($this->admin())->get('/login')->assertRedirect(route('dashboard'));
        $this->get('/register')->assertNotFound();   // no staff sign-up, signed in or not
    }

    public function test_logout_invalidates_session(): void
    {
        $this->actingAs($this->admin())->post('/logout')->assertRedirect(route('shop.home'))->assertSessionHas('shop_status', "You're signed out.");
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

    public function test_staff_app_account_cannot_sign_in_and_no_website_login_is_created(): void
    {
        $this->useFakeSupabase();
        // The right app e-mail and password of an active staff member: still the app only.
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'uid-cal#Pass1']));

        $this->assertNull(User::firstWhere('email', 'cora@melainuts.test'), 'no website login is created for staff');
        $this->assertTrue(ActivityLog::where('action', 'auth.login_refused')->exists());
        $this->get('/dashboard')->assertRedirect(route('login'));
    }

    public function test_old_staff_login_cannot_sign_in_with_the_app_password_and_stays_unlinked(): void
    {
        $this->useFakeSupabase();
        // A staff login from before (website registration approved by the owner): refused, not linked, no access given.
        $cora = User::factory()->create(['email' => 'cora@melainuts.test', 'role' => 'staff', 'has_access' => false]);
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'uid-cal#Pass1']));

        $this->assertSame(['staff', null, false], [$cora->fresh()->role, $cora->fresh()->staff_uid, $cora->fresh()->has_access]);
    }

    public function test_old_staff_login_becomes_the_owner_login_once_the_app_says_owner(): void
    {
        $this->useFakeSupabase();
        // Owner rights come only from the app's staff registry: a login made while the person was staff
        // is promoted at sign-in, once their app account is an active owner.
        $old = User::factory()->create(['email' => 'owner@melainuts.test', 'role' => 'staff', 'has_access' => true]);

        $this->post('/login', ['email' => 'owner@melainuts.test', 'password' => 'uid-owner#Pass1'])
            ->assertRedirect(route('dashboard'))->assertSessionHasNoErrors();
        $this->assertAuthenticatedAs($old->fresh());
        $this->assertSame(['admin', 'uid-owner', 'uid-owner'], [$old->fresh()->role, $old->fresh()->firebase_uid, $old->fresh()->staff_uid]);
        $this->assertTrue(ActivityLog::where('action', 'account.promoted_from_app_owner')->exists());
        $this->get('/dashboard')->assertOk()->assertSee('Los Baños Branch')->assertSee('Staff accounts');
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

    public function test_staff_website_password_is_refused_even_without_firebase_and_nothing_is_linked(): void
    {
        $this->useFakeSupabase();
        config(['services.firebase.web_api_key' => null]); // Firebase not configured: only website passwords are checked
        $cora = User::factory()->create(['email' => 'cora@melainuts.test', 'password' => 'Cora#Pass1', 'role' => 'staff', 'has_access' => true]);

        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'cora@melainuts.test', 'password' => 'Cora#Pass1']));
        $this->assertNull($cora->fresh()->staff_uid);
        $this->assertSame([], $this->db->calls, 'the app database is never asked for a staff login');
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
        $this->followingRedirects()->get('/login')->assertOk()->assertSee('data-start-open', false)
            ->assertSee('Please sign in again')->assertDontSee('Account not linked');
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

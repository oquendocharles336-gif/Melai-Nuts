<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeFirebase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Website sign-in through Firebase Authentication (fake Firebase with real signed
 * tokens; DATA_SOURCE=mock, so nothing here needs the Supabase database).
 */
class FirebaseAuthTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install();
    }

    public function test_waiting_page_picks_up_the_verified_email(): void
    {
        // An owner login that has no access yet (its app link is not verified) and an unverified e-mail.
        $user = User::factory()->create(['email' => 'juan@example.com', 'role' => 'admin', 'has_access' => false]);
        $user->forceFill(['firebase_uid' => 'uid-juan', 'firebase_email_verified' => false])->save();
        $this->fb->addAccount('juan@example.com', 'uid-juan', 'Str0ng!Pass', verified: false);

        $this->signedIn($user)->get('/waiting')->assertOk()->assertSee('Verify your email')->assertSee('Staff do not use the website');
        $this->signedIn($user)->get('/dashboard')->assertRedirect(route('waiting'));
        $this->assertFalse($user->fresh()->firebase_email_verified);

        $this->fb->set('uid-juan', 'verified', true); // person clicked the link
        $this->signedIn($user)->get('/waiting')->assertOk()->assertSee('Email verified');
        $this->assertTrue($user->fresh()->firebase_email_verified);
    }

    public function test_bound_login_signs_in_with_the_app_password_only(): void
    {
        $u = User::factory()->create(['email' => 'pat@example.com', 'password' => 'Local#Pass1', 'role' => 'admin', 'has_access' => false]);
        $this->fb->addAccount('pat@example.com', 'uid-pat', 'App#Pass1');

        // First app sign-in binds the login to the Firebase account.
        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1'])->assertRedirect();
        $this->assertAuthenticatedAs($u->fresh());
        $this->assertSame('uid-pat', $u->fresh()->firebase_uid);
        $this->assertTrue(ActivityLog::where('action', 'account.firebase_bound')->exists());
        $this->post('/logout');

        // The old local password stops working; the app password works.
        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'Local#Pass1'])->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1']);
        $this->assertAuthenticated();
    }

    public function test_legacy_local_login_still_works_without_an_app_account(): void
    {
        $u = User::factory()->create(['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1', 'role' => 'admin', 'has_access' => true]);
        $this->post('/login', ['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($u);
        $this->assertNull($u->fresh()->firebase_uid);
    }

    public function test_unverified_identity_cannot_sign_in_when_verification_is_required(): void
    {
        config(['services.firebase.require_verified_email' => true]);
        $u = User::factory()->create(['email' => 'pat@example.com', 'role' => 'admin', 'has_access' => true]);
        $u->forceFill(['firebase_uid' => 'uid-pat'])->save();
        $this->fb->addAccount('pat@example.com', 'uid-pat', 'App#Pass1', verified: false);

        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('verified email', session('errors')->first('auth'));
        $this->assertGuest();

        $this->fb->set('uid-pat', 'verified', true);
        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1']);
        $this->assertAuthenticatedAs($u->fresh());
    }

    public function test_disabled_app_account_is_told_so(): void
    {
        $this->fb->addAccount('pat@example.com', 'uid-pat', 'App#Pass1');
        $this->fb->set('uid-pat', 'disabled', true);
        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('disabled', session('errors')->first('auth'));
        $this->assertGuest();
    }

    public function test_missing_api_key_is_reported_to_firebase_bound_logins(): void
    {
        $u = User::factory()->create(['email' => 'pat@example.com', 'role' => 'admin']);
        $u->forceFill(['firebase_uid' => 'uid-pat'])->save();
        config(['services.firebase.web_api_key' => null]);

        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'anything'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('FIREBASE_WEB_API_KEY', session('errors')->first('auth'));
        $this->get('/?panel=sign-in')->assertSee('FIREBASE_WEB_API_KEY'); // shown in the panel, not only in the session
    }

    public function test_forgot_password_sends_our_own_reset_link_without_revealing_accounts(): void
    {
        $this->fb->withAccountEmails()->addAccount('pat@example.com', 'uid-pat', 'App#Pass1');
        $this->from('/forgot-password')->post('/forgot-password', ['email' => 'Pat@Example.com'])->assertSessionHas('status');
        $this->from('/forgot-password')->post('/forgot-password', ['email' => 'nobody@example.com'])->assertSessionHas('status');
        $this->assertSame(['pat@example.com', 'nobody@example.com'], $this->fb->resetEmails);
    }

    public function test_firebase_check_command(): void
    {
        $this->artisan('melai:firebase-check')->expectsOutputToContain('OK')->assertSuccessful();

        $this->fb->keyProject = 'another-project';
        $this->artisan('melai:firebase-check')->expectsOutputToContain('belongs to Firebase project "another-project"')->assertFailed();

        config(['services.firebase.web_api_key' => null]);
        $this->artisan('melai:firebase-check')->expectsOutputToContain('FIREBASE_WEB_API_KEY')->assertFailed();
    }

    public function test_a_staff_login_cannot_sign_in_with_the_app_password_or_an_old_local_one(): void
    {
        // Bound to an app account (app password) ...
        $bound = User::factory()->create(['email' => 'pat@example.com', 'role' => 'staff', 'has_access' => true]);
        $bound->forceFill(['firebase_uid' => 'uid-pat'])->save();
        $this->fb->addAccount('pat@example.com', 'uid-pat', 'App#Pass1', true);
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'pat@example.com', 'password' => 'App#Pass1']));

        // ... or a legacy login with the website's own password.
        User::factory()->create(['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1', 'role' => 'staff', 'has_access' => true]);
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1']));

        $this->assertFalse(ActivityLog::where('action', 'auth.login')->exists());
        $this->assertTrue(ActivityLog::where('action', 'auth.login_refused')->exists());
    }

    public function test_old_pending_registration_cannot_sign_in_before_or_after_it_is_registered_as_staff(): void
    {
        $this->useFakeSupabase();
        // Registered on the website before registration was removed: a Firebase account, no staff row yet.
        $u = User::factory()->create(['email' => 'new@melainuts.test', 'role' => 'staff', 'has_access' => false]);
        $u->forceFill(['firebase_uid' => 'uid-new', 'firebase_email_verified' => true])->save();
        $this->fb->addAccount('new@melainuts.test', 'uid-new', 'New#Pass1', true);

        // No waiting page any more: staff do not use the website.
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'new@melainuts.test', 'password' => 'New#Pass1']));
        $this->assertStaffKeptOut($this->signedIn($u)->get('/waiting'));

        // The owner registers the account as staff in the app: it works in the app, and still not here.
        $this->db->staff['uid-new'] = ['firebase_uid' => 'uid-new', 'full_name' => 'New Staff', 'email' => 'new@melainuts.test', 'role' => 'staff', 'branch_id' => 'b-cal', 'account_status' => 'active'];
        $this->assertStaffSignInRefused($this->post('/login', ['email' => 'new@melainuts.test', 'password' => 'New#Pass1']));
        $this->assertNull($u->fresh()->staff_uid);
        $this->assertFalse($u->fresh()->has_access);
        $this->get('/dashboard')->assertRedirect(route('login'));
    }
}

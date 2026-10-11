<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;
use Tests\Support\FakeFirebase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Website registration / sign-in through Firebase Authentication (fake Firebase with real signed
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

    private function reg(array $o = []): array
    {
        return array_merge(['name' => 'Juan Dela Cruz', 'email' => 'juan@example.com',
            'password' => 'Str0ng!Pass', 'password_confirmation' => 'Str0ng!Pass'], $o);
    }

    public function test_registration_creates_the_firebase_account_and_a_login_without_access_or_rights(): void
    {
        $this->post('/register', $this->reg(['email' => ' Juan@Example.com ', 'role' => 'admin', 'has_access' => 1]))
            ->assertRedirect(route('waiting'));

        $acc = $this->fb->accounts['juan@example.com'] ?? null;
        $this->assertNotNull($acc, 'the Firebase Authentication account must exist');
        $user = User::firstWhere('email', 'juan@example.com');
        $this->assertSame($acc['uid'], $user->firebase_uid, 'the login uses the real Firebase UID');
        $this->assertSame('staff', $user->role);            // role can't be injected
        $this->assertFalse($user->has_access);              // no access until an owner approves
        $this->assertNull($user->staff_uid);                // no app staff/owner rights
        $this->assertFalse(Hash::check('Str0ng!Pass', $user->password), 'Firebase holds the password, not the website');
        $this->assertContains($acc['uid'], $this->fb->verificationEmails, 'Firebase sends the verification email');
        $this->assertAuthenticatedAs($user);
        $this->assertDatabaseHas('activity_logs', ['action' => 'account.created', 'user_id' => $user->id]);

        $this->get('/waiting')->assertOk()->assertSee('Verify your email')->assertSee('An owner approves you');
        $this->get('/dashboard')->assertRedirect(route('waiting'));
    }

    public function test_waiting_page_picks_up_the_verified_email(): void
    {
        $this->post('/register', $this->reg());
        $user = User::firstWhere('email', 'juan@example.com');
        $this->assertFalse($user->firebase_email_verified);

        $this->fb->set($user->firebase_uid, 'verified', true); // person clicked the link
        $this->get('/waiting')->assertOk()->assertSee('Email verified');
        $this->assertTrue($user->fresh()->firebase_email_verified);
    }

    public function test_duplicate_app_account_with_another_password_is_refused_without_creating_anything(): void
    {
        $this->fb->addAccount('juan@example.com', 'existing-uid', 'TheirOwn#Pass9');

        $this->post('/register', $this->reg())->assertSessionHasErrors('email');
        $this->assertStringContainsString('already exists', session('errors')->first('email'));
        $this->assertCount(1, $this->fb->accounts);
        $this->assertDatabaseMissing('users', ['email' => 'juan@example.com']);
        $this->assertGuest();
    }

    public function test_failed_local_save_deletes_the_new_firebase_account(): void
    {
        User::creating(function (User $u) {
            if ($u->email === 'juan@example.com') {
                throw new \RuntimeException('disk full');
            }
        });

        try {
            $this->withoutExceptionHandling()->post('/register', $this->reg());
            $this->fail('expected the save to fail');
        } catch (\RuntimeException $e) {
            $this->assertSame('disk full', $e->getMessage());
        }
        $this->assertArrayNotHasKey('juan@example.com', $this->fb->accounts, 'no orphaned Firebase account');
        $this->assertDatabaseMissing('users', ['email' => 'juan@example.com']);
    }

    public function test_firebase_unreachable_gives_a_clear_temporary_error(): void
    {
        $this->fb->offline = true;
        $this->post('/register', $this->reg())->assertSessionHasErrors('auth');
        $this->assertStringContainsString('Could not reach', session('errors')->first('auth'));
        $this->assertDatabaseMissing('users', ['email' => 'juan@example.com']);
    }

    public function test_bound_login_signs_in_with_the_app_password_only(): void
    {
        $u = User::factory()->create(['email' => 'pat@example.com', 'password' => 'Local#Pass1', 'role' => 'staff', 'has_access' => false]);
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
        $u = User::factory()->create(['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1', 'role' => 'staff', 'has_access' => true]);
        $this->post('/login', ['email' => 'legacy@example.com', 'password' => 'Legacy#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($u);
        $this->assertNull($u->fresh()->firebase_uid);
    }

    public function test_unverified_identity_cannot_sign_in_when_verification_is_required(): void
    {
        config(['services.firebase.require_verified_email' => true]);
        $u = User::factory()->create(['email' => 'pat@example.com', 'role' => 'staff', 'has_access' => true]);
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
        $u = User::factory()->create(['email' => 'pat@example.com', 'role' => 'staff']);
        $u->forceFill(['firebase_uid' => 'uid-pat'])->save();
        config(['services.firebase.web_api_key' => null]);

        $this->post('/login', ['email' => 'pat@example.com', 'password' => 'anything'])->assertSessionHasErrors('auth');
        $this->assertStringContainsString('FIREBASE_WEB_API_KEY', session('errors')->first('auth'));
        $this->get('/login')->assertSee('FIREBASE_WEB_API_KEY'); // shown on the page, not only in the session
    }

    public function test_forgot_password_sends_a_firebase_reset_link_without_revealing_accounts(): void
    {
        $this->fb->addAccount('pat@example.com', 'uid-pat', 'App#Pass1');
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

    public function test_pending_registration_signs_in_to_the_waiting_page_and_is_linked_once_approved(): void
    {
        $this->useFakeSupabase();
        $u = User::factory()->create(['email' => 'new@melainuts.test', 'role' => 'staff', 'has_access' => false]);
        $u->forceFill(['firebase_uid' => 'uid-new', 'firebase_email_verified' => true])->save();
        $this->fb->addAccount('new@melainuts.test', 'uid-new', 'New#Pass1', true);

        // Not in staff_members yet: no dead end, no refusal; the existing waiting flow.
        $this->post('/login', ['email' => 'new@melainuts.test', 'password' => 'New#Pass1'])->assertRedirect(route('waiting'));
        $this->assertAuthenticatedAs($u->fresh());
        $this->assertNull($u->fresh()->staff_uid);

        // The owner registers the account in the app: the next check links it with no extra step.
        $this->db->staff['uid-new'] = ['firebase_uid' => 'uid-new', 'full_name' => 'New Staff', 'email' => 'new@melainuts.test', 'role' => 'staff', 'branch_id' => 'b-cal', 'account_status' => 'active'];
        $this->get('/waiting')->assertRedirect(route('dashboard'));
        $this->assertSame('uid-new', $u->fresh()->staff_uid);
        $this->get('/dashboard')->assertOk()->assertSee('Calamba Branch')->assertDontSee('Los Baños Branch');
    }
}

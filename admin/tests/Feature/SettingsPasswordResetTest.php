<?php

namespace Tests\Feature;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Settings > "Send me a reset email": a Firebase reset link to the signed-in person's OWN email. */
class SettingsPasswordResetTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useFakeSupabase();
        $this->fb->withAccountEmails();
    }

    public function test_settings_shows_the_button_and_it_emails_only_the_signed_in_account(): void
    {
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/settings')->assertOk()->assertSee('Send me a reset email')
            ->assertSee('action="'.route('settings.password-reset').'"', false)
            ->assertDontSee('href="'.route('password.request').'"', false);

        // Any email in the request is ignored: the link only ever goes to the account's own address.
        $this->signedIn($owner)->post('/settings/password-reset', ['email' => 'someone-else@example.com'])
            ->assertRedirect(route('settings'))->assertSessionHas('status', fn ($m) => str_contains($m, $owner->email));
        $this->assertSame([$owner->email], $this->fb->resetEmails);
        $this->assertTrue(ActivityLog::where('action', 'auth.password_reset_requested')->where('user_id', $owner->id)->exists());
    }

    public function test_a_website_password_login_gets_no_email_and_a_clear_note(): void
    {
        $local = User::factory()->create(['role' => 'admin', 'has_access' => true]);   // no firebase_uid

        $this->actingAs($local)->get('/settings')->assertOk()->assertDontSee('Send me a reset email');
        $this->actingAs($local)->post('/settings/password-reset')
            ->assertRedirect(route('settings'))->assertSessionHas('error', fn ($m) => str_contains($m, 'website password'));
        $this->assertSame([], $this->fb->resetEmails);
    }

    public function test_guests_staff_and_customers_cannot_use_it(): void
    {
        $this->post('/settings/password-reset')->assertRedirect(route('login'));
        $this->assertStaffKeptOut($this->signedIn($this->linkedLogin('uid-cal'))->post('/settings/password-reset'));   // staff: the app only
        $this->withSession(['shop_customer' => ['uid' => 'cust-1', 'email' => 'ana@example.com']])
            ->post('/settings/password-reset')->assertForbidden();   // customers never reach admin actions
        $this->assertSame([], $this->fb->resetEmails);
    }

    public function test_change_email_needs_the_current_password_and_only_sends_a_confirmation(): void
    {
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->get('/settings')->assertOk()->assertSee('Change email')->assertSee('action="'.route('settings.email').'"', false);

        $this->signedIn($owner)->post('/settings/email', ['new_email' => 'owner.new@example.com', 'current_password' => 'wrong'])
            ->assertSessionHasErrors('current_password');
        $this->assertSame([], $this->fb->emailChangeRequests);

        $this->signedIn($owner)->post('/settings/email', ['new_email' => $owner->email, 'current_password' => 'uid-owner#Pass1'])
            ->assertSessionHasErrors('new_email');

        $this->signedIn($owner)->post('/settings/email', ['new_email' => 'Owner.New@example.com', 'current_password' => 'uid-owner#Pass1'])
            ->assertRedirect(route('settings'))->assertSessionHas('status', fn ($m) => str_contains($m, 'owner.new@example.com'));
        $this->assertSame([['uid-owner', 'owner.new@example.com']], $this->fb->emailChangeRequests);
        $this->assertSame($owner->email, $owner->fresh()->email, 'nothing changes before the new address confirms');
    }
}

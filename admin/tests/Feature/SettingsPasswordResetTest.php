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
    }

    public function test_settings_shows_the_button_and_it_emails_only_the_signed_in_account(): void
    {
        $staff = $this->linkedLogin('uid-cal');

        $this->signedIn($staff)->get('/settings')->assertOk()->assertSee('Send me a reset email')
            ->assertSee('action="'.route('settings.password-reset').'"', false)
            ->assertDontSee('href="'.route('password.request').'"', false);

        // Any email in the request is ignored: the link only ever goes to the account's own address.
        $this->signedIn($staff)->post('/settings/password-reset', ['email' => 'someone-else@example.com'])
            ->assertRedirect(route('settings'))->assertSessionHas('status', fn ($m) => str_contains($m, $staff->email));
        $this->assertSame([$staff->email], $this->fb->resetEmails);
        $this->assertTrue(ActivityLog::where('action', 'auth.password_reset_requested')->where('user_id', $staff->id)->exists());
    }

    public function test_a_website_password_login_gets_no_email_and_a_clear_note(): void
    {
        $local = User::factory()->create(['role' => 'staff', 'has_access' => true]);   // no firebase_uid

        $this->actingAs($local)->get('/settings')->assertOk()->assertDontSee('Send me a reset email');
        $this->actingAs($local)->post('/settings/password-reset')
            ->assertRedirect(route('settings'))->assertSessionHas('error', fn ($m) => str_contains($m, 'website password'));
        $this->assertSame([], $this->fb->resetEmails);
    }

    public function test_guests_and_customers_cannot_use_it(): void
    {
        $this->post('/settings/password-reset')->assertRedirect(route('login'));
        $this->withSession(['shop_customer' => ['uid' => 'cust-1', 'email' => 'ana@example.com']])
            ->post('/settings/password-reset')->assertForbidden();   // customers never reach admin actions
        $this->assertSame([], $this->fb->resetEmails);
    }
}

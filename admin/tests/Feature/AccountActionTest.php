<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/**
 * The landing page of our account e-mails (<APP_URL>/auth/action, links from the account-email
 * function): password reset with our own single-use token, e-mail change confirm / cancel.
 * Firebase's oobCode links are gone.
 */
class AccountActionTest extends TestCase
{
    use RefreshDatabase;

    private FakeFirebase $fb;
    private string $token;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install()->withAccountEmails()->addAccount('ana@example.com', 'uid-ana', 'Old#Pass2026', true);
        $this->token = $this->fb->issueLink('password_reset', 'ana@example.com');
    }

    public function test_a_valid_link_shows_the_form_for_that_account(): void
    {
        $this->get('/auth/action?mode=resetPassword&token='.$this->token)->assertOk()
            ->assertSee('Choose a new password')->assertSee('ana@example.com')
            ->assertSee('name="token"', false)->assertDontSee('oobCode')
            ->assertHeader('Referrer-Policy', 'no-referrer');
    }

    public function test_the_app_password_rules_apply(): void
    {
        $this->post('/auth/action/reset', ['token' => $this->token, 'password' => 'short', 'password_confirmation' => 'short'])
            ->assertSessionHasErrors('password');
        $this->post('/auth/action/reset', ['token' => $this->token, 'password' => 'Ana#example1', 'password_confirmation' => 'Ana#example1'])
            ->assertSessionHasErrors('password');   // contains the e-mail name
        $this->assertSame('Old#Pass2026', $this->fb->accounts['ana@example.com']['password']);
    }

    public function test_the_password_is_changed_once_other_sign_ins_end_and_the_link_then_stops_working(): void
    {
        $this->post('/auth/action/reset', ['token' => $this->token, 'password' => 'Kasoy#Roast10', 'password_confirmation' => 'Kasoy#Roast10'])
            ->assertOk()->assertSee('Password changed');
        $this->assertSame('Kasoy#Roast10', $this->fb->accounts['ana@example.com']['password']);
        $this->assertTrue($this->fb->accounts['ana@example.com']['revoked'], 'old sessions end');

        $this->get('/auth/action?mode=resetPassword&token='.$this->token)->assertOk()
            ->assertSee('This link does not work')->assertSee('already used')->assertSee('Request a new reset link');
        $this->post('/auth/action/reset', ['token' => $this->token, 'password' => 'Kasoy#Roast11', 'password_confirmation' => 'Kasoy#Roast11'])
            ->assertSee('This link does not work');
        $this->assertSame('Kasoy#Roast10', $this->fb->accounts['ana@example.com']['password']);
    }

    public function test_an_incomplete_old_or_foreign_link_is_refused(): void
    {
        $this->get('/auth/action?mode=resetPassword')->assertOk()->assertSee('not complete');
        $this->get('/auth/action?mode=resetPassword&oobCode=x')->assertOk()->assertSee('older email');
        $this->get('/auth/action?mode=somethingElse&token='.$this->token)->assertOk()->assertSee('not one of ours');
    }

    public function test_an_email_change_applies_only_after_the_new_address_confirms(): void
    {
        $confirm = $this->fb->issueLink('email_change', 'ana@example.com', 'ana.new@example.com');
        // Opening the link only shows a button (link scanners must not use it up).
        $this->get('/auth/action?mode=confirmEmail&token='.$confirm)->assertOk()->assertSee('Confirm your new email');
        $this->assertArrayHasKey('ana@example.com', $this->fb->accounts);
        $this->post('/auth/action/confirm-email', ['token' => $confirm])->assertOk()->assertSee('ana.new@example.com');
        $this->assertArrayHasKey('ana.new@example.com', $this->fb->accounts);
        $this->post('/auth/action/confirm-email', ['token' => $confirm])->assertSee('already used');
    }

    public function test_the_old_address_can_stop_a_change(): void
    {
        $cancel = $this->fb->issueLink('email_change_cancel', 'ana@example.com', 'ana.new@example.com');
        $this->get('/auth/action?mode=cancelEmailChange&token='.$cancel)->assertOk()->assertSee('Stop the email change?');
        $this->post('/auth/action/cancel-email', ['token' => $cancel])->assertOk()->assertSee('Change stopped');
        $this->assertArrayHasKey('ana@example.com', $this->fb->accounts);
    }

    public function test_assetlinks_is_served_only_when_configured(): void
    {
        $this->get('/.well-known/assetlinks.json')->assertNotFound();
        config(['melai.android.app_link_sha256' => 'AA:BB']);
        $this->get('/.well-known/assetlinks.json')->assertOk()
            ->assertJsonPath('0.target.package_name', 'ph.melainuts.app')
            ->assertJsonPath('0.target.sha256_cert_fingerprints.0', 'AA:BB');
    }
}

<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Tests\Support\FakeFirebase;
use Tests\TestCase;

/**
 * The landing page of Firebase's password-reset e-mail (custom action URL <APP_URL>/auth/action):
 * a real code is checked with Firebase, the new password follows the app's rules, the code works once.
 */
class AccountActionTest extends TestCase
{
    use RefreshDatabase;

    /** @var array<string, string> oobCode => e-mail, removed once used */
    private array $codes = ['good-code' => 'ana@example.com'];

    private array $passwords = [];

    protected function setUp(): void
    {
        parent::setUp();
        Http::fake([
            'identitytoolkit.googleapis.com/v1/accounts:resetPassword*' => function (Request $r) {
                $code = (string) $r['oobCode'];
                if (! isset($this->codes[$code])) {
                    return Http::response(['error' => ['message' => 'INVALID_OOB_CODE']], 400);
                }
                $email = $this->codes[$code];
                if (isset($r['newPassword'])) {
                    $this->passwords[$email] = (string) $r['newPassword'];
                    unset($this->codes[$code]);   // single use, like Firebase
                }

                return Http::response(['email' => $email, 'requestType' => 'PASSWORD_RESET']);
            },
        ]);
        (new FakeFirebase)->install();
    }

    public function test_a_valid_link_shows_the_form_for_that_account(): void
    {
        $this->get('/auth/action?mode=resetPassword&oobCode=good-code')->assertOk()
            ->assertSee('Choose a new password')->assertSee('ana@example.com')
            ->assertHeader('Referrer-Policy', 'no-referrer');
    }

    public function test_the_app_password_rules_apply(): void
    {
        $this->post('/auth/action/reset', ['oobCode' => 'good-code', 'password' => 'short', 'password_confirmation' => 'short'])
            ->assertSessionHasErrors('password');
        $this->post('/auth/action/reset', ['oobCode' => 'good-code', 'password' => 'Ana#example1', 'password_confirmation' => 'Ana#example1'])
            ->assertSessionHasErrors('password');   // contains the e-mail name
        $this->assertSame([], $this->passwords);
    }

    public function test_the_password_is_changed_once_and_the_link_then_stops_working(): void
    {
        $this->post('/auth/action/reset', ['oobCode' => 'good-code', 'password' => 'Kasoy#Roast10', 'password_confirmation' => 'Kasoy#Roast10'])
            ->assertOk()->assertSee('Password changed');
        $this->assertSame(['ana@example.com' => 'Kasoy#Roast10'], $this->passwords);

        $this->get('/auth/action?mode=resetPassword&oobCode=good-code')->assertOk()
            ->assertSee('This link does not work')->assertSee('already used')->assertSee('Request a new reset link');
        $this->post('/auth/action/reset', ['oobCode' => 'good-code', 'password' => 'Kasoy#Roast11', 'password_confirmation' => 'Kasoy#Roast11'])
            ->assertSee('This link does not work');
        $this->assertSame('Kasoy#Roast10', $this->passwords['ana@example.com']);
    }

    public function test_an_incomplete_or_foreign_link_is_refused_without_calling_firebase(): void
    {
        $this->get('/auth/action?mode=resetPassword')->assertOk()->assertSee('not complete');
        $this->get('/auth/action?mode=somethingElse&oobCode=x')->assertOk()->assertSee('not one of ours');
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

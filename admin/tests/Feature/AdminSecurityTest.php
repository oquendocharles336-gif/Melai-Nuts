<?php

namespace Tests\Feature;

use App\Http\Requests\Rules;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Validator;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Panel criteria on the website: shared field rules (1), admin protection and rate limits (2),
 * error pages (8) and the Terms / Privacy pages and consent (11).
 */
class AdminSecurityTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_password_rules_match_the_app(): void
    {
        $fails = fn (string $pw, ?string $email = null, ?string $name = null) => Validator::make(
            ['password' => $pw], ['password' => Rules::newPassword($email, $name)])->fails();

        $this->assertFalse($fails('Kasoy#Tanim42'));
        $this->assertTrue($fails('Password1!'), 'common password');
        $this->assertTrue($fails('P@ssw0rd1!'), 'common password with symbol swaps');
        $this->assertTrue($fails('Mariel#2026', 'mariel@mail.ph'), 'contains the email name');
        $this->assertTrue($fails('Santos#2026x', null, 'Ana Santos'), 'contains the name');
        $this->assertTrue($fails('Aa1!'.str_repeat('x', 61)), 'over 64 characters');
        $this->assertTrue($fails('kasoytanim#42'), 'no uppercase');
    }

    public function test_names_accept_filipino_letters_and_phones_are_stored_as_e164(): void
    {
        foreach (['Niño', 'Ñora', 'Dela Cruz-Reyes', "O'Brien", 'Ma. Cristina'] as $name) {
            $this->assertFalse(Validator::make(['name' => $name], ['name' => Rules::name()])->fails(), $name);
        }
        $this->assertTrue(Validator::make(['name' => 'Juan 3'], ['name' => Rules::name()])->fails());

        $this->assertSame('+639171234567', Rules::normalizePhone('0917 123 4567'));
        $this->assertSame('+639171234567', Rules::normalizePhone('63-917-123-4567'));
        $this->assertNull(Rules::phToE164('028123456'));
        $this->assertTrue(Validator::make(['phone' => '12345'], ['phone' => Rules::phone()])->fails());
        $this->assertFalse(Validator::make(['phone' => ''], ['phone' => Rules::phone()])->fails());
    }

    public function test_free_text_rejects_emoji_only_and_money_allows_two_decimals(): void
    {
        $this->assertTrue(Validator::make(['r' => '👍👍👍👍👍👍👍👍👍👍'], ['r' => Rules::reason()])->fails());
        $this->assertFalse(Validator::make(['r' => 'Stale cashews in the pack'], ['r' => Rules::reason()])->fails());
        $this->assertTrue(Validator::make(['m' => '10.555'], ['m' => Rules::money()])->fails());
        $this->assertFalse(Validator::make(['m' => '10.55'], ['m' => Rules::money()])->fails());
    }

    public function test_terms_and_privacy_pages_are_public_and_registration_needs_consent(): void
    {
        $this->get('/terms')->assertOk()->assertSee('Terms and Conditions')->assertSee('Loyalty points');
        $this->get('/privacy')->assertOk()->assertSee('Republic Act No. 10173')->assertSee('National Privacy Commission');
        $this->get('/login')->assertOk()->assertSee(route('legal.terms'), false)->assertSee(route('legal.privacy'), false);
        $this->get('/register')->assertOk()->assertSee('name="terms"', false)->assertDontSee('name="terms" value="1" checked', false);

        $this->post('/register', ['name' => 'Ana Reyes', 'email' => 'ana@example.com',
            'password' => 'Kasoy#Tanim42', 'password_confirmation' => 'Kasoy#Tanim42'])
            ->assertSessionHasErrors('terms');
    }

    public function test_an_admin_must_turn_on_two_step_sign_in_first(): void
    {
        config(['melai.two_factor.required_for_admins' => true]);
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->get('/dashboard')->assertRedirect(route('two-factor.show'));
        $this->signedIn($owner)->get('/two-factor')->assertOk();
        $this->signedIn($owner)->getJson('/ui/counts.json')->assertStatus(423);
    }

    public function test_every_change_is_rate_limited_and_429_has_its_own_page(): void
    {
        config(['melai.write_limit_per_minute' => 2]);
        // Invalid registrations never reach Firebase; they still count as changes.
        $this->post('/register', [])->assertSessionHasErrors('name');
        $this->post('/register', [])->assertSessionHasErrors('name');
        $this->post('/register', [])->assertStatus(429)->assertSee('Too many requests');
        $this->get('/terms')->assertOk(); // reads are never limited
    }

    public function test_error_pages_never_show_details(): void
    {
        $this->get('/no-such-page-here')->assertNotFound()->assertSee('Page not found')->assertDontSee('Stack trace');
    }
}

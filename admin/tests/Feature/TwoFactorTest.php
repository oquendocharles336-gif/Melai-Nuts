<?php

namespace Tests\Feature;

use App\Http\Middleware\EnsureTwoFactorPassed;
use App\Services\Auth\Totp;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Optional two-step sign-in (TOTP, RFC 6238) for staff logins. Admins never use it. */
class TwoFactorTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_rfc_6238_reference_code(): void
    {
        $secret = Totp::base32Encode('12345678901234567890');
        $this->assertSame('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', $secret);
        $this->assertSame('287082', Totp::code($secret, intdiv(59, 30)));      // RFC 6238 T=59 -> 94287082
        $this->assertSame('081804', Totp::code($secret, intdiv(1111111109, 30))); // T=1111111109 -> 07081804
        $this->assertTrue(Totp::verify($secret, '287 082', null, 59));
        $this->assertTrue(Totp::verify($secret, Totp::code($secret, 1 + 1), null, 59), 'one step of clock drift is fine');
        $this->assertFalse(Totp::verify($secret, Totp::code($secret, 1 + 3), null, 59));
        $this->assertFalse(Totp::verify($secret, 'abcdef', null, 59));
    }

    public function test_a_code_cannot_be_replayed(): void
    {
        $secret = Totp::generateSecret();
        $code = Totp::code($secret, intdiv(time(), 30));
        $this->assertTrue(Totp::verify($secret, $code, 'u1'));
        $this->assertFalse(Totp::verify($secret, $code, 'u1'));
    }

    public function test_turn_on_then_every_new_session_needs_a_code_and_recovery_codes_work_once(): void
    {
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');
        $this->fb->addAccount($staff->email, 'uid-cal', 'right-password', true);

        $this->signedIn($staff)->post('/two-factor', ['current_password' => 'wrong'])->assertSessionHasErrors('current_password');
        $this->signedIn($staff)->post('/two-factor', ['current_password' => 'right-password'])->assertRedirect(route('two-factor.show'));
        $secret = $staff->fresh()->two_factor_secret;
        $this->assertNotEmpty($secret);
        $this->assertNotSame($secret, \DB::table('users')->where('id', $staff->id)->value('two_factor_secret'), 'stored encrypted');
        $this->assertFalse($staff->fresh()->hasTwoFactor(), 'not required until confirmed');
        $this->signedIn($staff)->get('/two-factor')->assertOk()->assertSee('otpauth://totp/', false);

        $this->signedIn($staff)->post('/two-factor/confirm', ['code' => '000000'])->assertSessionHasErrors('code');
        $r = $this->signedIn($staff)->post('/two-factor/confirm', ['code' => Totp::code($secret, intdiv(time(), 30))]);
        $r->assertRedirect(route('two-factor.show'));
        $codes = session('recovery_codes');
        $this->assertCount(8, $codes);
        $staff = $staff->fresh();
        $this->assertTrue($staff->hasTwoFactor());

        // A new session (fresh sign-in or "remember me") is held at the challenge.
        $this->flushSession();
        $this->signedIn($staff)->get('/dashboard')->assertRedirect(route('two-factor.challenge'));
        $this->signedIn($staff)->get('/two-factor/challenge')->assertOk()->assertSee('Enter code');
        $this->signedIn($staff)->post('/two-factor/challenge', ['code' => '111111'])->assertSessionHasErrors('code');
        $this->signedIn($staff)->post('/two-factor/challenge', ['code' => strtolower($codes[0])])->assertRedirect();
        $this->assertSame($staff->id, session(EnsureTwoFactorPassed::SESSION_KEY));
        $this->assertCount(7, $staff->fresh()->two_factor_recovery_codes);

        $this->flushSession();
        $this->signedIn($staff)->post('/two-factor/challenge', ['code' => $codes[0]])->assertSessionHasErrors('code'); // used up

        // Turning it off needs the password AND a code.
        $this->flushSession();
        $this->withSession([EnsureTwoFactorPassed::SESSION_KEY => $staff->id]);
        $this->signedIn($staff)->delete('/two-factor', ['current_password' => 'right-password', 'code' => '000000'])->assertSessionHasErrors('code');
        $this->signedIn($staff)->delete('/two-factor', ['current_password' => 'right-password', 'code' => $codes[1]])->assertRedirect(route('two-factor.show'));
        $this->assertFalse($staff->fresh()->hasTwoFactor());
        $this->assertNull($staff->fresh()->two_factor_secret);
    }

    public function test_without_two_step_sign_in_nothing_changes(): void
    {
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');
        $this->signedIn($staff)->get('/dashboard')->assertOk();
        $this->signedIn($staff)->get('/two-factor/challenge')->assertRedirect(route('dashboard'));
        $this->signedIn($staff)->get('/settings')->assertOk()->assertSee('Set up two-step sign-in');
    }
}

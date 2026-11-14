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

    public function test_nobody_reaches_two_step_sign_in_on_the_website_any_more(): void
    {
        // Two-step sign-in was for STAFF logins. Staff no longer use the website (the Melai Nuts app only),
        // and the owner never needed it (AdminSecurityTest): so no login can turn it on or be held by it.
        $this->useFakeSupabase();
        $staff = $this->linkedLogin('uid-cal');
        $this->fb->addAccount($staff->email, 'uid-cal', 'right-password', true);
        // Even a staff login that still holds a confirmed authenticator from before.
        $staff->forceFill(['two_factor_secret' => Totp::generateSecret(), 'two_factor_confirmed_at' => now()])->save();

        $this->assertStaffKeptOut($this->signedIn($staff)->get('/dashboard'));
        $this->assertStaffKeptOut($this->signedIn($staff)->get('/two-factor'));
        $this->assertStaffKeptOut($this->signedIn($staff)->get('/two-factor/challenge'));
        $this->assertStaffKeptOut($this->signedIn($staff)->post('/two-factor', ['current_password' => 'right-password']));
        $this->assertStaffKeptOut($this->signedIn($staff)->post('/two-factor/challenge', ['code' => '111111']));
        $this->assertNull(session(EnsureTwoFactorPassed::SESSION_KEY));

        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->get('/dashboard')->assertOk();
        $this->signedIn($owner)->get('/two-factor')->assertRedirect(route('dashboard'));
        $this->signedIn($owner)->post('/two-factor', ['current_password' => 'uid-owner#Pass1'])->assertRedirect(route('dashboard'));
        $this->assertNull($owner->fresh()->two_factor_secret);
        $this->signedIn($owner)->get('/settings')->assertOk()->assertDontSee('two-step sign-in');
    }
}

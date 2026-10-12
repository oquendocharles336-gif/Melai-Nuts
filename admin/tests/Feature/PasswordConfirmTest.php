<?php

namespace Tests\Feature;

use App\Http\Middleware\ConfirmRecentPassword;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/** Refunds and points adjustments need the password again (checked by Firebase for app accounts). */
class PasswordConfirmTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_points_adjustment_without_the_password_is_refused_before_anything_runs(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->from('/loyalty/x')
            ->post(route('admin.loyalty.adjust', 'someone'), ['points' => 10, 'reason' => 'Goodwill', 'request_key' => 'abcdefgh12'])
            ->assertSessionHasErrors('current_password');
        $this->assertNotContains('owner_adjust_loyalty_points', $this->db->calledFunctions('uid-owner'));
    }

    public function test_marking_a_payment_paid_needs_the_password_like_the_other_money_actions(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->from('/admin/payments')
            ->post(route('admin.payments.mark-paid', 'ORD-1'))
            ->assertSessionHasErrors('current_password');
        $this->assertNotContains('staff_confirm_payment', $this->db->calledFunctions('uid-owner'));
        $this->assertStringContainsString('<x-password-confirm />', file_get_contents(resource_path('views/admin/payments/index.blade.php')));
    }

    public function test_a_wrong_password_is_refused_and_rate_limited(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->fb->addAccount($owner->email, 'uid-owner', 'right-password', true);
        for ($i = 0; $i < 5; $i++) {
            $this->signedIn($owner)->post('/admin/refunds/ORD-1/approve', ['current_password' => 'wrong'])
                ->assertSessionHasErrors(['current_password' => 'That password is not correct.']);
        }
        $this->signedIn($owner)->post('/admin/refunds/ORD-1/approve', ['current_password' => 'right-password'])
            ->assertSessionHasErrors('current_password'); // locked out for a few minutes
        $this->assertStringContainsString('Too many', session('errors')->first('current_password'));
    }

    public function test_the_right_password_passes_and_is_remembered_for_a_few_minutes(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $this->fb->addAccount($owner->email, 'uid-owner', 'right-password', true);

        $r = $this->signedIn($owner)->post('/admin/refunds/NO-SUCH-ORDER/approve', ['current_password' => 'right-password']);
        $r->assertNotFound(); // reached the controller: the password step passed
        $this->assertNotNull(session(ConfirmRecentPassword::SESSION_KEY));

        $this->post('/admin/refunds/NO-SUCH-ORDER/approve')->assertNotFound(); // no password needed again yet

        $this->withSession([ConfirmRecentPassword::SESSION_KEY => time() - 301])
            ->post('/admin/refunds/NO-SUCH-ORDER/approve')->assertSessionHasErrors('current_password');
    }

    public function test_a_password_of_another_firebase_account_does_not_count(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        // Same email at Firebase but a different UID than this login is bound to.
        $this->fb->addAccount($owner->email, 'uid-someone-else', 'pw-123456', true);
        $this->signedIn($owner)->post('/admin/refunds/ORD-1/approve', ['current_password' => 'pw-123456'])
            ->assertSessionHasErrors(['current_password' => 'That password is not correct.']);
    }

    public function test_the_forms_ask_for_the_password(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $html = file_get_contents(resource_path('views/admin/refunds/index.blade.php')).file_get_contents(resource_path('views/admin/loyalty/show.blade.php'));
        $this->assertSame(4, substr_count($html, '<x-password-confirm />'));
    }
}

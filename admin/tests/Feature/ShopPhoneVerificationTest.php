<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeFirebase;
use Tests\Support\FakeShopSupabase;
use Tests\TestCase;

/**
 * Shop checkout needs a verified mobile number (migration 20261118040000): Firebase sends and checks
 * the SMS code and links the number to the customer's own account; the database takes the number
 * from the refreshed ID token only (claim_verified_phone).
 */
class ShopPhoneVerificationTest extends TestCase
{
    use RefreshDatabase;

    private FakeFirebase $fb;

    private FakeShopSupabase $shop;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install();
        $this->shop = (new FakeShopSupabase)->install();
        $this->shop->phoneVerified = false;
        $uid = 'cust-1';
        $this->fb->addAccount('ana@example.com', $uid, 'Kasoy#Roast9', verified: true);
        $this->fb->profiles[$uid] = ['email' => 'ana@example.com', 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true, 'phone' => '+639171234567'];
        $this->shop->profiles[$uid] = ['firebase_uid' => $uid, 'full_name' => 'Ana Cruz', 'phone' => '+639171234567'];
        $this->shop->legal[$uid] = ['terms_version' => config('melai.legal.terms_version'), 'privacy_version' => config('melai.legal.privacy_version')];
        $this->post('/login', ['email' => 'ana@example.com', 'password' => 'Kasoy#Roast9'])->assertRedirect(route('shop.home'));
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
    }

    public function test_checkout_sends_an_unverified_customer_to_the_sms_step(): void
    {
        $this->get('/shop/checkout')->assertRedirect(route('shop.phone', ['next' => '/shop/checkout']));
        $this->get(route('shop.phone'))->assertOk()
            ->assertSee('Verify your mobile number')
            ->assertSee('data-sitekey="test-site-key"', false)
            ->assertSee('https://www.google.com/recaptcha/api.js', false);
    }

    public function test_no_sms_without_the_security_check(): void
    {
        $this->post(route('shop.phone.send'), ['phone' => '0917 765 4321'])->assertSessionHasErrors('g-recaptcha-response');
        $this->assertSame([], $this->fb->phoneCodesSent);
    }

    public function test_the_code_links_the_number_and_the_database_takes_it_from_the_token(): void
    {
        $this->post(route('shop.phone.send'), ['phone' => '0917 765 4321', 'g-recaptcha-response' => 'tok', 'next' => '/shop/checkout'])
            ->assertRedirect();
        $this->assertSame(['+639177654321'], $this->fb->phoneCodesSent, 'normalized to E.164 before Firebase sees it');
        $this->get(route('shop.phone'))->assertSee('+639177654321')->assertSee('6-digit code');

        $this->post(route('shop.phone.confirm'), ['code' => '000000'])->assertSessionHasErrors('code');
        $this->assertSame([], $this->shop->verifiedPhones);

        $this->post(route('shop.phone.confirm'), ['code' => '123456', 'next' => '/shop/checkout'])->assertRedirect('/shop/checkout');
        $this->assertSame(['cust-1' => '+639177654321'], $this->shop->verifiedPhones);
        $this->get('/shop/checkout')->assertOk();
    }

    public function test_a_number_on_another_account_is_refused(): void
    {
        $this->fb->phonesTaken = ['+639177654321'];
        $this->post(route('shop.phone.send'), ['phone' => '09177654321', 'g-recaptcha-response' => 'tok']);
        $this->post(route('shop.phone.confirm'), ['code' => '123456'])
            ->assertSessionHasErrors(['code' => 'This mobile number is already used by another Melai Nuts account. Sign in to that account, or use a different number.']);
        $this->assertSame([], $this->shop->verifiedPhones);
    }

    public function test_only_pages_of_this_site_are_followed_afterwards(): void
    {
        $this->post(route('shop.phone.send'), ['phone' => '09177654321', 'g-recaptcha-response' => 'tok']);
        $this->post(route('shop.phone.confirm'), ['code' => '123456', 'next' => 'https://evil.example/'])
            ->assertRedirect(route('shop.checkout'));
    }
}

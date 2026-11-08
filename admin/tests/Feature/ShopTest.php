<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeFirebase;
use Tests\Support\FakeShopSupabase;
use Tests\TestCase;

/**
 * The customer shop: browsing, the guest cart, sign-in and sign-up with the app account, and
 * checkout through the same database functions as the app (store pickup only, server-decided
 * downpayment, HitPay).
 */
class ShopTest extends TestCase
{
    use RefreshDatabase;

    private FakeFirebase $fb;

    private FakeShopSupabase $shop;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install();
        $this->shop = (new FakeShopSupabase)->install();
    }

    private function customerAccount(string $uid = 'cust-1', string $email = 'ana@example.com'): void
    {
        $this->fb->addAccount($email, $uid, 'Kasoy#Roast9', verified: true);
        $this->fb->profiles[$uid] = ['email' => $email, 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true, 'phone' => '+639171234567'];
        $this->shop->profiles[$uid] = ['firebase_uid' => $uid, 'full_name' => 'Ana Cruz', 'phone' => '+639171234567'];
        $this->shop->legal[$uid] = ['terms_version' => config('melai.legal.terms_version'), 'privacy_version' => config('melai.legal.privacy_version')];
    }

    private function signIn(): void
    {
        $this->customerAccount();
        $this->post('/login', ['email' => 'ana@example.com', 'password' => 'Kasoy#Roast9'])->assertRedirect(route('shop.home'));
    }

    // ---- Browsing ------------------------------------------------------------------------------

    public function test_the_shop_is_the_home_page_and_shows_real_products(): void
    {
        $this->get('/')->assertOk()
            ->assertSee('Small-batch nuts, <em>roasted</em> the slow way.', false)
            ->assertSee('Chili Garlic Peanuts')
            ->assertSee('Roasted Cashew')
            ->assertSee('Pickup at')       // the only open branch is picked automatically
            ->assertSee('Santa Cruz Branch');
    }

    public function test_search_matches_every_word_and_says_so_when_nothing_matches(): void
    {
        $this->get('/shop/search?q=spicy+garlic')->assertOk()->assertSee('Chili Garlic Peanuts')->assertDontSee('Roasted Cashew');
        $this->get('/shop/search?q=pistachio')->assertOk()->assertSee('No nuts match');
    }

    public function test_an_unconfigured_shop_says_so_instead_of_breaking(): void
    {
        config(['melai.shop.supabase_url' => null]);
        $this->get('/')->assertOk()->assertSee('The shop is not set up yet.');
    }

    // ---- Guest cart, sign-in, back to the cart --------------------------------------------------

    public function test_a_guest_can_fill_a_cart_without_touching_the_server_cart(): void
    {
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])
            ->assertOk()->assertJson(['added' => 2, 'count' => 2]);
        $this->get('/shop/cart')->assertOk()->assertSee('Chili Garlic Peanuts')->assertSee('Sign in to check out');
        $this->assertSame([], $this->shop->called('sync_customer_cart'));
    }

    public function test_adding_more_than_the_branch_has_is_capped_with_a_clear_message(): void
    {
        $this->postJson('/shop/cart', ['product' => 'p-2', 'variant' => 'v-2', 'qty' => 5])
            ->assertOk()->assertJson(['added' => 3, 'message' => 'Only 3 more available. Added 3 to your cart.']);
        $this->postJson('/shop/cart', ['product' => 'p-2', 'variant' => 'v-2'])
            ->assertStatus(422)->assertJson(['message' => 'You already have all 3 available in your cart.']);
    }

    public function test_checkout_asks_a_guest_to_sign_in_then_returns_with_the_cart_added_to_the_account(): void
    {
        $this->customerAccount();
        $this->shop->carts['cust-1']['br-1'] = ['items' => [['product_id' => 'p-1', 'variant_id' => 'v-1', 'quantity' => 1]], 'voucher_code' => null, 'redeem_points' => false];
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->postJson('/shop/cart', ['product' => 'p-2', 'variant' => 'v-2', 'qty' => 3])->assertOk();

        $this->get('/shop/checkout')->assertRedirect(route('login'));
        $this->post('/login', ['email' => 'ana@example.com', 'password' => 'Kasoy#Roast9'])
            ->assertRedirect(route('shop.checkout'));

        // Same items add up; done as the customer, through the app's own cart function.
        $sync = $this->shop->asCustomer('sync_customer_cart');
        $this->assertCount(1, $sync);
        $items = collect($sync[0]['body']['p_items'])->keyBy('variant_id');
        $this->assertSame(3, $items['v-1']['quantity']);
        $this->assertSame(3, $items['v-2']['quantity']);
        $this->assertSame([], session('shop_guest_cart', []));
        $this->assertGuest('web');
    }

    // ---- Sign-up with the app account ------------------------------------------------------------

    public function test_sign_up_uses_the_apps_rules(): void
    {
        $this->post('/shop/register', [
            'name' => 'A1', 'email' => 'not-an-email', 'phone' => '12345', 'password' => 'password1', 'password_confirmation' => 'password1',
        ])->assertSessionHasErrors(['name', 'email', 'phone', 'password', 'terms']);
        $this->assertSame([], $this->fb->accounts);
    }

    public function test_sign_up_mistakes_show_inside_the_create_account_panel(): void
    {
        $this->post('/shop/register', ['_panel' => 'create-account', 'name' => 'Bea Santos', 'email' => 'bea@example.com', 'phone' => '12345',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1'])
            ->assertRedirect('/?panel=create-account')->assertSessionHasErrors('phone');
        $page = $this->get('/')->assertOk()->assertSee('data-start-open', false)->assertSee('data-shown="create-account"', false)
            ->assertSee('value="Bea Santos"', false)->assertDontSee('Pili#Nut2026');
        $this->assertStringContainsString('has-err', $page->getContent());
        $this->assertSame([], $this->fb->accounts);
    }

    public function test_reset_password_from_the_panel_comes_back_to_sign_in_with_a_note(): void
    {
        $this->post('/shop/forgot-password', ['_panel' => 'reset-password', 'email' => 'nope'])->assertRedirect('/?panel=reset-password')->assertSessionHasErrors('email');
        $this->post('/shop/forgot-password', ['_panel' => 'reset-password', 'email' => 'bea@example.com'])->assertRedirect('/?panel=sign-in');
        $this->get('/?panel=sign-in')->assertSee("we've sent a link to reset your password");
    }

    public function test_sign_up_verifies_the_email_then_creates_the_same_profiles_as_the_app(): void
    {
        $this->post('/shop/register', [
            'name' => 'Bea Santos', 'email' => 'bea@example.com', 'phone' => '0917 123 4567',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1', 'order_updates' => '1',
        ])->assertRedirect(route('shop.verify'));
        $uid = $this->fb->accounts['bea@example.com']['uid'];
        $this->assertSame([$uid], $this->fb->verificationEmails);

        // Not verified yet: nothing is created, the customer is asked to open the link.
        $this->post('/shop/verify-email')->assertRedirect(route('shop.verify'))->assertSessionHas('shop_error');
        $this->assertArrayNotHasKey($uid, $this->fb->profiles);

        // The link was opened.
        $this->fb->set($uid, 'verified', true);
        $this->post('/shop/verify-email')->assertRedirect(route('shop.home'));

        $this->assertSame('customer', $this->fb->profiles[$uid]['role']);
        $this->assertSame('+639171234567', $this->fb->profiles[$uid]['phone']);
        $this->assertSame(['firebase_uid' => $uid, 'full_name' => 'Bea Santos', 'email' => 'bea@example.com', 'phone' => '+639171234567'], $this->shop->profiles[$uid]);
        $this->assertSame(config('melai.legal.terms_version'), $this->shop->legal[$uid]['terms_version']);
        $this->assertTrue(session()->has('shop_customer'));
        $this->assertGuest('web');
    }

    // ---- Checkout ------------------------------------------------------------------------------

    public function test_a_cash_pickup_order_is_placed_through_place_order_as_store_pickup(): void
    {
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertSee('Santa Cruz Branch')->assertSee('Mon–Sat 8am–6pm')->assertSee('Pay the full amount in cash');

        $this->post('/shop/checkout', ['payment' => 'counter', 'notes' => 'Pasalubong box please'])
            ->assertRedirect(route('shop.orders.show', ['order' => 'ORD-1001', 'placed' => 1]));

        $params = $this->shop->orders[0]['_params'];
        $this->assertFalse($params['p_is_delivery']);
        $this->assertSame('Cash on Counter Pickup', $params['p_payment_method']);
        $this->assertSame('Pasalubong box please', $params['p_customer_notes']);
        $this->assertNotEmpty($params['p_idempotency_key']);
        $this->assertSame([], $this->shop->paymentRequests, 'a plain cash order opens no payment page');

        $this->get('/shop/orders/ORD-1001?placed=1')->assertOk()->assertSee('Salamat po! Your order is in.');
    }

    public function test_a_double_click_places_one_order(): void
    {
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $cart = app(\App\Services\Shop\ShopCart::class)->view();

        $first = app(\App\Services\Shop\ShopOrders::class)->place($cart, 'Cash on Counter Pickup', '');
        session()->put('shop_checkout_attempt', ['fingerprint' => hash('sha256', json_encode([$cart['cart_id'], 'Cash on Counter Pickup', '', null, false, ['v-1x1']])), 'key' => $this->shop->orders[0]['_key']]);
        $second = app(\App\Services\Shop\ShopOrders::class)->place($cart, 'Cash on Counter Pickup', '');

        $this->assertSame($first, $second);
        $this->assertCount(1, $this->shop->orders);
    }

    public function test_a_pickup_downpayment_goes_straight_to_hitpay_and_returns_to_the_website(): void
    {
        $this->shop->quote = ['required' => true, 'amount' => 66, 'balance' => 154, 'percent' => 30, 'expiry_minutes' => 30, 'pickup_days' => 2];
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertSee('30% downpayment')->assertSee('Place order &amp; pay', false);

        $this->post('/shop/checkout', ['payment' => 'counter'])
            ->assertRedirect('https://securecheckout.sandbox.hit-pay.com/payment-request/ORD-1001');

        $this->assertSame([['order_id' => 'ORD-1001', 'return_to' => 'web']], $this->shop->paymentRequests);
        // HitPay sends the customer back here; the page checks the order, it never trusts the URL.
        $this->get('/shop/payment/return?reference=abc&status=completed')
            ->assertRedirect(route('shop.orders.show', ['order' => 'ORD-1001', 'checking' => 1]));
    }

    public function test_online_payment_is_refused_while_it_is_switched_off(): void
    {
        $this->shop->onlinePayment = false;
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();

        $this->post('/shop/checkout', ['payment' => 'online'])->assertRedirect()->assertSessionHas('shop_error', 'Online payment is paused.');
        $this->assertSame([], $this->shop->orders);
    }

    public function test_customer_data_is_read_and_written_as_the_customer_never_with_the_public_key(): void
    {
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->post('/shop/checkout', ['payment' => 'counter'])->assertRedirect();
        $this->get('/shop/orders')->assertOk()->assertSee('ORD-1001');
        $this->get('/shop/points')->assertOk()->assertSee('120');

        foreach (['get_customer_cart', 'sync_customer_cart', 'place_order', '/orders', 'customer_profiles', 'loyalty_'] as $path) {
            $calls = $this->shop->called($path);
            $this->assertNotEmpty($calls, $path);
            foreach ($calls as $c) {
                $this->assertNotSame(FakeShopSupabase::ANON, $c['token'], "$path must run as the customer");
            }
        }
    }

    public function test_checkout_and_orders_need_a_signed_in_customer(): void
    {
        foreach (['/shop/checkout', '/shop/orders', '/shop/orders/ORD-1', '/shop/points', '/shop/account'] as $uri) {
            $this->get($uri)->assertRedirect(route('login'));
        }
        $this->post('/shop/checkout', ['payment' => 'counter'])->assertRedirect(route('login'));
    }

    public function test_a_customer_only_sees_their_own_orders(): void
    {
        $this->signIn();
        $this->shop->orders[] = ['_key' => 'k', 'id' => 'ORD-9999', 'firebase_uid' => 'someone-else'] + array_fill_keys(['branch_id', 'branch_name', 'status', 'total', 'created_at', 'payment_method'], '');
        $this->get('/shop/orders/ORD-9999')->assertNotFound();
    }
}

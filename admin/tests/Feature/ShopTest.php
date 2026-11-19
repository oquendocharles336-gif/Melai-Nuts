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

    public function test_a_customer_changes_email_only_with_the_password_and_a_confirmation(): void
    {
        $this->signIn();
        $this->get('/shop/account')->assertOk()->assertSee('Change email')->assertSee('action="'.route('shop.account.email').'"', false);
        $this->post('/shop/account/email', ['new_email' => 'ana.new@example.com', 'current_password' => 'nope'])
            ->assertSessionHasErrors('current_password');
        $this->post('/shop/account/email', ['new_email' => 'ana.new@example.com', 'current_password' => 'Kasoy#Roast9'])
            ->assertRedirect(route('shop.account'))->assertSessionHas('shop_status', fn ($m) => str_contains($m, 'ana.new@example.com'));
        $this->assertSame([['cust-1', 'ana.new@example.com']], $this->fb->emailChangeRequests);
    }

    public function test_the_pickup_branch_can_be_picked_by_hand_when_location_is_off(): void
    {
        $this->get('/')->assertOk()->assertSee('data-loc-fallback', false)->assertSee('Finding your nearest branch', false);
        $branch = $this->shop->branches[0]['id'];
        $this->post('/shop/branch', ['branch_id' => $branch])->assertRedirect()->assertSessionHas('shop_status');
        $this->postJson('/shop/branch', ['branch_id' => 'no-such-branch'])->assertStatus(422);
        $this->postJson('/shop/branch', [])->assertStatus(422)->assertJsonValidationErrors(['branch_id', 'latitude']);
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
            'first_name' => 'Ana1', 'last_name' => 'D', 'email' => 'not-an-email', 'phone' => '12345', 'password' => 'password1', 'password_confirmation' => 'password2',
        ])->assertSessionHasErrors([
            'first_name' => "First name can't contain numbers.",
            'last_name' => 'Last name must be at least 2 characters.',
            'email' => 'Email must look like name@example.com.',
            'phone' => 'Mobile number must be 11 digits starting with 09.',
            'password' => 'Password must contain at least one uppercase letter (A-Z).',
            'password_confirmation' => 'Passwords do not match.',
            'terms',
        ]);
        $this->post('/shop/register', ['first_name' => 'Ana', 'last_name' => 'Cruz', 'email' => 'ana@gmial.com', 'phone' => '0917 123 4567'])
            ->assertSessionHasErrors(['email' => 'Did you mean ana@gmail.com? Please check the spelling.',
                'phone' => 'Mobile number can only contain digits, e.g. 09171234567.']);
        $this->assertSame([], $this->fb->accounts);
    }

    public function test_sign_up_verifies_the_security_check_on_the_server_before_creating_anything(): void
    {
        $form = ['first_name' => 'Bea', 'last_name' => 'Santos', 'email' => 'bea@example.com', 'phone' => '09171234567',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1'];
        // No token / a refused token: an error under the security check, no Firebase account.
        $this->post('/shop/register', $form + ['_panel' => 'create-account'])->assertSessionHasErrors(['captcha' => 'Please complete the security check.']);
        $this->post('/shop/register', $form + ['cf-turnstile-response' => 'bad-token'])->assertSessionHasErrors(['captcha' => 'The security check failed. Please try again.']);
        $this->assertSame([], $this->fb->accounts);
        // No secret key on the server: a friendly message, the detail only in the log.
        config(['melai.captcha.turnstile_secret_key' => '']);
        \Illuminate\Support\Facades\Log::spy();
        $this->post('/shop/register', $form + ['cf-turnstile-response' => 'tok'])
            ->assertSessionHasErrors(['captcha' => 'The security check is not available right now, so we can\'t create accounts at the moment. Please try again later.']);
        \Illuminate\Support\Facades\Log::shouldHaveReceived('error')->withArgs(fn ($m) => str_contains($m, 'TURNSTILE_SECRET_KEY is empty'));
        $this->assertSame([], $this->fb->accounts);
    }

    public function test_the_create_account_form_has_first_and_last_name_and_hides_env_names(): void
    {
        config(['melai.captcha.turnstile_site_key' => '']);
        $page = $this->get('/?panel=create-account')->assertOk()
            ->assertSee('name="first_name"', false)->assertSee('name="last_name"', false)->assertDontSee('name="name"', false)
            ->assertSee('data-signup', false)
            ->assertSee('The security check can\'t load right now', false)->assertDontSee('TURNSTILE_SITE_KEY');
        config(['melai.captcha.turnstile_site_key' => 'site-key-123']);
        $this->get('/?panel=create-account')->assertOk()->assertSee('data-sitekey="site-key-123"', false);
        unset($page);
    }

    public function test_a_website_sign_up_is_always_a_customer_whatever_the_request_says(): void
    {
        $this->post('/shop/register', ['first_name' => 'Ola', 'last_name' => 'Owner', 'email' => 'ola@example.com', 'phone' => '09171234500',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1',
            'role' => 'owner', 'is_staff' => '1', 'staff_role' => 'admin', 'cf-turnstile-response' => 'tok'])->assertRedirect(route('shop.verify'));
        $uid = $this->fb->accounts['ola@example.com']['uid'];
        $this->shop->onEmailVerified = fn (string $verifiedUid) => $this->fb->set($verifiedUid, 'verified', true);
        $this->post('/shop/verify-email', ['code' => '123456', 'cf-turnstile-response' => 'tok-2'])->assertRedirect(route('shop.home'));
        $this->assertSame('customer', $this->fb->profiles[$uid]['role']);
        $this->assertSame(0, \App\Models\User::count(), 'no website login (staff / admin) is created');
    }

    public function test_the_app_download_link_shows_in_the_footer_and_sign_in_panel_when_set(): void
    {
        config(['melai.shop.app_download_url' => 'https://www.mediafire.com/file/abc123/MelaiNuts-v1.0.0.apk/file']);
        $link = '<a href="https://www.mediafire.com/file/abc123/MelaiNuts-v1.0.0.apk/file" target="_blank" rel="noopener noreferrer">';

        $html = $this->get('/?panel=sign-in')->assertOk()
            ->assertSee('Get the Melai Nuts app for Android')
            ->assertSee('Prefer the app?')
            ->assertSee('Download it for Android')
            ->assertSee('Android only. Your phone may ask you to allow installs from your browser.')
            ->getContent();
        $this->assertSame(1, substr_count($html, $link.'Download it for Android</a>'), 'sign-in panel link');
        $this->assertStringContainsString('rel="noopener noreferrer"><svg', $html, 'footer link with its icon');
        $this->assertSame(2, substr_count($html, 'href="https://www.mediafire.com/file/abc123/MelaiNuts-v1.0.0.apk/file" target="_blank" rel="noopener noreferrer"'));
    }

    public function test_every_app_link_is_hidden_when_the_download_url_is_empty(): void
    {
        foreach ([null, '', '   '] as $empty) {
            config(['melai.shop.app_download_url' => $empty]);
            $this->get('/?panel=sign-in')->assertOk()
                ->assertSee('Create an account')
                ->assertDontSee('Get the Melai Nuts app')
                ->assertDontSee('Prefer the app?')
                ->assertDontSee('Android only.');
        }
    }

    public function test_the_sign_in_panel_says_plainly_how_to_sign_in(): void
    {
        $this->get('/?panel=sign-in')->assertOk()
            ->assertSee('Sign in with your Melai Nuts email and password.')
            ->assertDontSee("owner's dashboard", false)
            ->assertDontSee('One sign-in for the shop');
    }

    public function test_the_staff_note_on_sign_in_is_short_and_quiet(): void
    {
        // The rule itself (staff cannot sign in here) is tested in AuthTest / AccessControlTest.
        $this->get('/?panel=sign-in')->assertOk()
            ->assertSee('<p class="s-dlg-aside">Staff? Please sign in using the Melai Nuts app.</p>', false)
            ->assertDontSee('not on this website');
    }

    public function test_sign_up_mistakes_show_inside_the_create_account_panel(): void
    {
        $this->post('/shop/register', ['_panel' => 'create-account', 'first_name' => 'Bea', 'last_name' => 'Santos', 'email' => 'bea@example.com', 'phone' => '12345',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1'])
            ->assertRedirect('/?panel=create-account')->assertSessionHasErrors('phone');
        $page = $this->get('/')->assertOk()->assertSee('data-start-open', false)->assertSee('data-shown="create-account"', false)
            ->assertSee('value="Bea"', false)->assertSee('value="Santos"', false)->assertDontSee('Pili#Nut2026');
        $this->assertStringContainsString('has-err', $page->getContent());
        $this->assertSame([], $this->fb->accounts);
    }

    public function test_reset_password_from_the_panel_comes_back_to_sign_in_with_a_note(): void
    {
        $this->post('/shop/forgot-password', ['_panel' => 'reset-password', 'email' => 'nope'])->assertRedirect('/?panel=reset-password')->assertSessionHasErrors('email');
        $this->post('/shop/forgot-password', ['_panel' => 'reset-password', 'email' => 'bea@example.com'])->assertRedirect('/?panel=sign-in');
        $this->get('/?panel=sign-in')->assertSee("If an account exists for this email, we've sent a reset link.");
    }

    public function test_sign_up_verifies_the_email_then_creates_the_same_profiles_as_the_app(): void
    {
        $this->post('/shop/register', [
            'first_name' => 'Bea', 'last_name' => 'Santos', 'email' => 'bea@example.com', 'phone' => '09171234567',
            'password' => 'Pili#Nut2026', 'password_confirmation' => 'Pili#Nut2026', 'terms' => '1', 'order_updates' => '1',
            'cf-turnstile-response' => 'turnstile-token-1',
        ])->assertRedirect(route('shop.verify'));
        $uid = $this->fb->accounts['bea@example.com']['uid'];
        // The website verified the token with Cloudflare first, then passed the same key on.
        $this->assertSame('turnstile-token-1', $this->shop->siteverified[0]['token']);
        $this->assertSame('test-turnstile-secret', $this->shop->siteverified[0]['secret']);
        $this->assertSame([$this->shop->siteverified[0]['key']], $this->shop->codeCaptchaKeys);
        // The 6-digit code comes from Melai Nuts' own e-mail function; Firebase sends nothing.
        $this->assertSame([$uid], $this->shop->codesSent);
        $this->assertSame([], $this->fb->verificationEmails);
        $this->shop->onEmailVerified = fn (string $verifiedUid) => $this->fb->set($verifiedUid, 'verified', true);

        // A wrong code: nothing is created.
        $this->post('/shop/verify-email', ['code' => '000000', 'cf-turnstile-response' => 'turnstile-token-2'])
            ->assertRedirect(route('shop.verify'))->assertSessionHas('shop_error');
        $this->assertArrayNotHasKey($uid, $this->fb->profiles);

        // No security check: refused, nothing is created.
        $this->post('/shop/verify-email', ['code' => '123456'])->assertRedirect(route('shop.verify'))->assertSessionHas('shop_error');
        $this->assertArrayNotHasKey($uid, $this->fb->profiles);

        // The right code with a security check.
        $this->post('/shop/verify-email', ['code' => '123 456', 'cf-turnstile-response' => 'turnstile-token-3'])->assertRedirect(route('shop.home'));

        $this->assertSame('customer', $this->fb->profiles[$uid]['role']);
        $this->assertSame('+639171234567', $this->fb->profiles[$uid]['phone']);
        $this->assertSame(['firebase_uid' => $uid, 'full_name' => 'Bea Santos', 'first_name' => 'Bea', 'last_name' => 'Santos', 'email' => 'bea@example.com', 'phone' => '+639171234567'], $this->shop->profiles[$uid]);
        $this->assertSame(config('melai.legal.terms_version'), $this->shop->legal[$uid]['terms_version']);
        $this->assertTrue(session()->has('shop_customer'));
        $this->assertGuest('web');
    }

    // ---- Checkout ------------------------------------------------------------------------------

    public function test_special_instructions_with_offensive_words_are_refused(): void
    {
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 1])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertSee('id="melai-blocked-words"', false)->assertSee('data-moderate', false);
        $this->post('/shop/checkout', ['payment' => 'counter', 'notes' => 'bilisan nyo tang1na'])
            ->assertSessionHasErrors(['notes' => 'Please keep your message respectful.']);
        $this->assertSame([], $this->shop->orders, 'no order was placed');
    }

    public function test_without_a_downpayment_cash_pickup_is_not_offered(): void
    {
        // Online first, every order (migration 20261119080000): no downpayment set = no cash order.
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->get('/shop/checkout')->assertOk()
            ->assertSee('Not available for this order right now. Please choose Pay online now.')
            ->assertSee('name="payment" value="counter"  disabled', false)
            ->assertDontSee('Pay the full amount in cash');
    }

    public function test_ordering_is_paused_while_online_payment_is_switched_off(): void
    {
        $this->shop->onlinePayment = false;
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->get('/shop/checkout')->assertOk()
            ->assertSee('Ordering is paused because online payment is unavailable right now.')
            ->assertDontSee('Cash on counter pickup')
            ->assertSee('form="checkout" disabled', false);
    }

    public function test_a_cash_pickup_order_is_placed_through_place_order_as_store_pickup(): void
    {
        $this->shop->quote = ['required' => true, 'amount' => 110, 'balance' => 110, 'percent' => 50, 'expiry_minutes' => 30, 'pickup_days' => 2];
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertSee('Santa Cruz Branch')->assertSee('Mon–Sat 8am–6pm')->assertSee('50% downpayment');

        $this->post('/shop/checkout', ['payment' => 'counter', 'notes' => 'Pasalubong box please'])
            ->assertRedirect('https://securecheckout.sandbox.hit-pay.com/payment-request/ORD-1001');

        $params = $this->shop->orders[0]['_params'];
        $this->assertFalse($params['p_is_delivery']);
        $this->assertSame('Cash on Counter Pickup', $params['p_payment_method']);
        $this->assertSame('Pasalubong box please', $params['p_customer_notes']);
        $this->assertNotEmpty($params['p_idempotency_key']);
        $this->assertSame([['order_id' => 'ORD-1001', 'return_to' => 'web']], $this->shop->paymentRequests, 'the downpayment is paid online first');

        $this->get('/shop/orders/ORD-1001?placed=1')->assertOk()->assertSee('Salamat po! Your order is in.')->assertSee('Pay the downpayment to confirm it.');
    }

    public function test_the_order_page_follows_the_status_live_until_the_order_is_done(): void
    {
        $this->shop->quote = ['required' => true, 'amount' => 55, 'balance' => 55, 'percent' => 50, 'expiry_minutes' => 30, 'pickup_days' => 2];
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->post('/shop/checkout', ['payment' => 'counter'])->assertRedirect();

        // Ready for pickup (downpayment paid online, cash balance still pending): the page watches the status.
        $this->shop->orders[0]['status'] = 'readyForPickup';
        $this->shop->orders[0]['order_downpayments'][0]['status'] = 'success';
        $this->shop->orders[0]['order_status_events'][] = ['id' => 'e2', 'status' => 'readyForPickup', 'note' => '', 'created_at' => '2026-11-08T06:00:00Z'];
        $this->get('/shop/orders/ORD-1001')->assertOk()
            ->assertSee('data-order-watch="'.route('shop.orders.status', 'ORD-1001').'"', false)
            ->assertSee('data-order-status="readyForPickup"', false)
            ->assertSee('Ready for pickup')->assertDontSee('<b>Completed</b>', false);
        $this->getJson('/shop/orders/ORD-1001/status.json')->assertOk()->assertJson(['status' => 'readyForPickup']);

        // Staff complete it at pickup: the status the page checks changes, and the reloaded page
        // shows the Completed step and stops watching.
        $this->shop->orders[0]['status'] = 'completed';
        $this->shop->orders[0]['payments'][0]['status'] = 'success';
        $this->shop->orders[0]['order_status_events'][] = ['id' => 'e3', 'status' => 'completed', 'note' => '', 'created_at' => '2026-11-08T06:10:00Z'];
        $this->getJson('/shop/orders/ORD-1001/status.json')->assertOk()->assertJson(['status' => 'completed', 'status_label' => 'Completed']);
        $this->get('/shop/orders/ORD-1001')->assertOk()
            ->assertSee('<b>Completed</b>', false)->assertSee('<b>Ready for pickup</b>', false)
            ->assertDontSee('data-order-watch', false);
    }

    public function test_points_on_an_order_need_the_loyalty_pin_when_one_is_set(): void
    {
        $this->shop->loyaltyPin = '4321';
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->post('/shop/cart/points', ['on' => 1])->assertRedirect();

        $this->get('/shop/checkout')->assertOk()->assertSee('name="loyalty_pin"', false)->assertSee('You set a PIN for your points.');

        // No PIN, or a wrong one: no order, the customer is told why.
        $this->post('/shop/checkout', ['payment' => 'online'])->assertSessionHasErrors('loyalty_pin');
        $this->post('/shop/checkout', ['payment' => 'online', 'loyalty_pin' => '9999'])
            ->assertSessionHasErrors(['loyalty_pin' => 'Wrong loyalty PIN. 4 tries left.']);
        $this->assertSame([], $this->shop->orders, 'no order without the right PIN');

        // The right PIN: checked once with the database, then the order is placed.
        $this->post('/shop/checkout', ['payment' => 'online', 'loyalty_pin' => '4321'])->assertRedirect();
        $this->assertCount(1, $this->shop->orders);
        $this->assertSame(['9999', '4321'], $this->shop->pinChecks);
    }

    public function test_without_a_pin_or_without_points_checkout_is_unchanged(): void
    {
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->post('/shop/cart/points', ['on' => 1])->assertRedirect();
        $this->get('/shop/checkout')->assertOk()->assertDontSee('name="loyalty_pin"', false);
        $this->post('/shop/checkout', ['payment' => 'online'])->assertRedirect()->assertSessionHasNoErrors();
        $this->assertCount(1, $this->shop->orders, 'no PIN set: the order goes through as before');
        $this->assertSame([], $this->shop->pinChecks, 'no PIN check at all');

        // A PIN holder who does not use points is not asked either.
        $this->shop->loyaltyPin = '4321';
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertDontSee('name="loyalty_pin"', false);
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

    public function test_a_first_order_offers_50_or_100_percent_online_and_sends_the_choice(): void
    {
        $this->shop->firstOrder = ['first_order' => true, 'total' => 220, 'half_amount' => 110, 'half_balance' => 110,
            'full_amount' => 220, 'expiry_minutes' => 30, 'pending_order_id' => null, 'online_payment_enabled' => true];
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1', 'qty' => 2])->assertOk();
        $this->get('/shop/checkout')->assertOk()
            ->assertSee('Your first order.')->assertSee('Pay 50% now')->assertSee('Pay 100% now')
            ->assertSee('₱110.00 online now, then ₱110.00 in cash when you pick it up.', false)
            ->assertDontSee('Cash on counter pickup');

        $this->post('/shop/checkout', ['payment' => 'half'])->assertRedirect();
        $params = $this->shop->orders[0]['_params'];
        $this->assertSame('Online Payment (GCash, QR Ph, Card)', $params['p_payment_method']);
        $this->assertSame('half', $params['p_first_order_payment']);
    }

    public function test_a_first_order_waiting_for_its_payment_blocks_a_second_one(): void
    {
        $this->shop->firstOrder = ['first_order' => true, 'total' => 110, 'half_amount' => 55, 'half_balance' => 55,
            'full_amount' => 110, 'expiry_minutes' => 30, 'pending_order_id' => 'ORD-0999', 'online_payment_enabled' => true];
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->get('/shop/checkout')->assertOk()->assertSee('ORD-0999')->assertSee('Pay for this order')->assertDontSee('Pay 50% now');
    }

    public function test_checkout_does_not_guess_when_the_first_order_check_cannot_be_loaded(): void
    {
        $this->shop->firstOrder = null;   // the server cannot answer
        $this->signIn();
        $this->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertOk();
        $this->get('/shop/checkout')->assertOk()
            ->assertSee('We couldn\'t load your payment options.', false)
            ->assertSee('disabled', false)
            ->assertDontSee('Cash on counter pickup');
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

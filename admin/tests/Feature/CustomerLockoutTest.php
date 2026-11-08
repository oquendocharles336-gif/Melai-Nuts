<?php

namespace Tests\Feature;

use App\Http\Middleware\KeepCustomersOut;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Routing\Route as LaravelRoute;
use Illuminate\Support\Facades\Route;
use Tests\Support\FakeShopSupabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Customers can use the shop, but must NEVER reach an admin / staff page or admin endpoint.
 * The refusal is on the server, for every route, not just hidden links.
 */
class CustomerLockoutTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private FakeShopSupabase $shop;

    protected function setUp(): void
    {
        parent::setUp();
        $this->useFakeSupabase();
        $this->shop = (new FakeShopSupabase)->install();
    }

    /** A real sign-in of a customer app account (Firestore role "customer") on the single login page. */
    private function signInCustomer(string $uid = 'cust-1', string $email = 'ana@example.com'): void
    {
        $this->fb->addAccount($email, $uid, 'Kasoy#Roast9', verified: true);
        $this->fb->profiles[$uid] = ['email' => $email, 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true];
        $this->shop->legal[$uid] = ['terms_version' => config('melai.legal.terms_version'), 'privacy_version' => config('melai.legal.privacy_version')];

        $this->post('/login', ['email' => $email, 'password' => 'Kasoy#Roast9'])->assertRedirect(route('shop.home'));
        $this->assertTrue(session()->has('shop_customer'), 'the customer is signed in to the shop');
        $this->assertGuest('web');
    }

    private function owner(): string
    {
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $s = $this->db->staff[$owner];
        $this->fb->profiles[$owner] = ['email' => $s['email'], 'name' => $s['full_name'], 'role' => 'owner', 'isActive' => true];

        return $owner;
    }

    /**
     * Every route that is part of the admin website: behind the admin login (`auth`) or marked
     * `no.customers`. Found from the router itself, so a route added later is covered too.
     */
    private function adminRoutes(): array
    {
        return collect(Route::getRoutes()->getRoutes())
            ->filter(fn (LaravelRoute $r) => array_intersect(['no.customers', 'auth'], $r->gatherMiddleware()) !== [])
            ->values()->all();
    }

    private function uri(LaravelRoute $r, User $someone): string
    {
        return '/'.ltrim(preg_replace_callback('/\{(\w+)\??\}/', fn ($m) => $m[1] === 'user' ? (string) $someone->id : 'x1', $r->uri()), '/');
    }

    public function test_every_admin_route_is_behind_the_customer_check(): void
    {
        $routes = $this->adminRoutes();
        $this->assertGreaterThan(60, count($routes), 'the admin website has many routes; all of them must be covered');
        foreach ($routes as $r) {
            $this->assertContains('no.customers', $r->gatherMiddleware(), $r->uri().' is behind the admin login but not the customer check');
        }
        $uris = array_map(fn ($r) => $r->uri(), $routes);
        foreach (['dashboard', 'orders', 'admin/payments', 'admin/users', 'admin/business-settings', 'dashboard/overview.json', 'ui/counts.json', 'logout'] as $must) {
            $this->assertContains($must, $uris, "$must is protected");
        }
        // And nothing in the shop is: customers keep using it.
        foreach ($uris as $uri) {
            $this->assertFalse(str_starts_with($uri, 'shop'), "$uri must not be an admin route");
        }
    }

    public function test_a_customer_typing_any_admin_page_is_sent_back_to_the_shop_with_no_access(): void
    {
        $this->signInCustomer();
        $someone = User::factory()->create();
        $this->assertGreaterThan(60, count($this->adminRoutes()));

        foreach ($this->adminRoutes() as $route) {
            $uri = $this->uri($route, $someone);
            foreach (array_diff($route->methods(), ['HEAD']) as $method) {
                $response = $this->call($method, $uri);
                if ($method === 'GET' && ! str_ends_with($uri, '.json')) {
                    $response->assertRedirect(route('shop.home'));
                    $response->assertSessionHas('shop_error', KeepCustomersOut::MESSAGE);
                } else {
                    $response->assertStatus(403);
                }
            }
        }
        $this->assertGuest('web');
    }

    public function test_admin_apis_reject_a_customer_with_403_json(): void
    {
        $this->signInCustomer();

        foreach (['/dashboard/overview.json', '/ui/counts.json', '/ui/pulse.json', '/ui/search.json?q=a', '/orders/catalog.json', '/orders/branches.json'] as $uri) {
            $this->getJson($uri)->assertStatus(403)->assertJson(['message' => KeepCustomersOut::MESSAGE]);
        }
        $this->postJson('/orders', ['branch_id' => 'b'])->assertStatus(403);
        $this->postJson('/admin/payments/ORD-1/mark-paid')->assertStatus(403);
        $this->postJson('/admin/app-accounts/cust-1/active', ['active' => false])->assertStatus(403);
        // Nothing reached the database as anyone.
        $this->assertSame([], $this->db->calledFunctions('cust-1'));
    }

    public function test_the_shop_message_shows_on_the_shop_page(): void
    {
        $this->signInCustomer();

        $this->followingRedirects()->get('/admin/users')->assertOk()->assertSee('It&#039;s for Melai Nuts staff only.', false);
    }

    public function test_one_login_sends_a_customer_to_the_shop_never_the_admin_side(): void
    {
        $this->signInCustomer();

        $this->assertGuest('web');
        $this->assertSame(0, \App\Models\User::where('email', 'ana@example.com')->count(), 'no website (admin) login is ever made for a customer');
        $this->get('/dashboard')->assertRedirect(route('shop.home'));
        $this->get('/login')->assertRedirect(route('shop.home'));
    }

    public function test_one_login_sends_staff_and_owners_to_the_dashboard(): void
    {
        $owner = $this->owner();
        $s = $this->db->staff[$owner];

        $this->post('/login', ['email' => $s['email'], 'password' => "$owner#Pass1"])->assertRedirect(route('dashboard'));
        $this->assertAuthenticated('web');
        $this->assertFalse(session()->has('shop_customer'));
        $this->get('/dashboard')->assertOk();
    }

    public function test_the_old_shop_sign_in_address_forwards_to_the_single_login(): void
    {
        $this->get('/shop/login')->assertRedirect(route('login'));
    }

    public function test_a_rider_account_is_refused_on_the_single_login(): void
    {
        $this->fb->addAccount('rider@example.com', 'rider-1', 'Kasoy#Roast9', verified: true);
        $this->fb->profiles['rider-1'] = ['email' => 'rider@example.com', 'name' => 'Rico', 'role' => 'delivery', 'isActive' => true];

        $this->post('/login', ['email' => 'rider@example.com', 'password' => 'Kasoy#Roast9'])->assertSessionHasErrors();
        $this->assertGuest('web');
        $this->assertFalse(session()->has('shop_customer'));
    }

    public function test_staff_still_reach_the_admin_side_as_before(): void
    {
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $this->signedIn($this->linkedLogin($owner))->get('/dashboard')->assertOk();
    }

    public function test_view_shop_lets_staff_browse_and_go_back_to_the_dashboard_without_signing_in_again(): void
    {
        (new FakeShopSupabase)->install();
        $login = $this->linkedLogin($this->owner());

        // Dashboard -> "View shop"
        $this->signedIn($login)->get('/dashboard')->assertOk()->assertSee('View shop')->assertSee(route('shop.home'), false);
        $this->signedIn($login)->get('/')->assertOk()
            ->assertSee('browse only')->assertSee('Back to dashboard')->assertSee(route('dashboard'), false)
            ->assertDontSee('Add to cart');
        $this->signedIn($login)->get('/shop/search')->assertOk()->assertDontSee('data-add-to-cart', false);
        // Shop -> "Back to dashboard": still signed in, no new sign-in.
        $this->signedIn($login)->get('/dashboard')->assertOk();
        $this->assertAuthenticatedAs($login, 'web');
    }

    public function test_staff_browsing_the_shop_cannot_order_with_their_admin_login(): void
    {
        (new FakeShopSupabase)->install();
        $login = $this->linkedLogin($this->owner());

        $this->signedIn($login)->postJson('/shop/cart', ['product' => 'p-1', 'variant' => 'v-1'])->assertStatus(403);
        $this->signedIn($login)->get('/shop/cart')->assertRedirect(route('shop.home'));
        $this->signedIn($login)->get('/shop/checkout')->assertRedirect(route('shop.home'));
        $this->signedIn($login)->post('/shop/checkout', ['payment' => 'counter'])->assertStatus(403);
        $this->signedIn($login)->get('/shop/orders')->assertRedirect(route('shop.home'));
    }

    public function test_one_logout_ends_every_sign_in(): void
    {
        // A customer signing out of the shop.
        $this->signInCustomer();
        $this->post('/shop/logout')->assertRedirect(route('shop.home'));
        $this->assertFalse(session()->has('shop_customer'));
        $this->get('/dashboard')->assertRedirect(route('login'));

        // Staff signing out from the admin side ends the admin login AND anything else in the session.
        $login = $this->linkedLogin($this->owner());
        $this->signedIn($login)->withSession(['shop_customer' => ['uid' => 'x'], 'shop_guest_cart' => ['v' => 1]])
            ->post('/logout')->assertRedirect(route('login'));
        $this->assertGuest('web');
        $this->assertFalse(session()->has('shop_customer'));
        $this->assertFalse(session()->has('firebase_auth'));
    }
}

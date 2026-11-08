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

    /** A real shop sign-in of a customer app account (Firestore role "customer"). */
    private function signInCustomer(string $uid = 'cust-1', string $email = 'ana@example.com'): void
    {
        $this->fb->addAccount($email, $uid, 'Kasoy#Roast9', verified: true);
        $this->fb->profiles[$uid] = ['email' => $email, 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true];

        $this->post('/shop/login', ['email' => $email, 'password' => 'Kasoy#Roast9'])->assertRedirect();
        $this->assertTrue(session()->has('shop_customer'), 'the customer is signed in to the shop');
        $this->assertGuest('web');
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

    public function test_a_customer_account_cannot_sign_in_to_the_admin_website(): void
    {
        $this->fb->addAccount('ana@example.com', 'cust-1', 'Kasoy#Roast9', verified: true);
        $this->fb->profiles['cust-1'] = ['email' => 'ana@example.com', 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true];

        $this->post('/login', ['email' => 'ana@example.com', 'password' => 'Kasoy#Roast9'])->assertRedirect();
        $this->assertGuest('web');
        $this->get('/dashboard')->assertRedirect(route('login'));
    }

    public function test_staff_and_owner_accounts_are_sent_to_their_own_sign_in_from_the_shop(): void
    {
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $s = $this->db->staff[$owner];
        $this->fb->profiles[$owner] = ['email' => $s['email'], 'name' => $s['full_name'], 'role' => 'owner', 'isActive' => true];

        $this->post('/shop/login', ['email' => $s['email'], 'password' => "$owner#Pass1"])
            ->assertRedirect()->assertSessionHas('shop_error', 'This is a staff account. Please use the staff sign-in instead.');
        $this->assertFalse(session()->has('shop_customer'));
        $this->assertGuest('web');
    }

    public function test_staff_still_reach_the_admin_side_as_before(): void
    {
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $this->signedIn($this->linkedLogin($owner))->get('/dashboard')->assertOk();
    }

    public function test_a_staff_member_who_also_shops_keeps_admin_access_through_their_admin_login(): void
    {
        $owner = array_key_first(array_filter($this->db->staff, fn ($s) => $s['role'] === 'owner'));
        $login = $this->linkedLogin($owner);
        $this->signInCustomer('cust-9', 'owner-personal@example.com');

        // The shop sign-in never logs anyone in to the admin side...
        $this->get('/dashboard')->assertRedirect(route('shop.home'));
        // ...but their own admin login works exactly as before.
        $this->signedIn($login)->get('/dashboard')->assertOk();
    }

    public function test_signing_out_of_the_shop_never_signs_anyone_in(): void
    {
        $this->signInCustomer();
        $this->post('/shop/logout')->assertRedirect(route('shop.home'));
        $this->assertFalse(session()->has('shop_customer'));
        $this->get('/dashboard')->assertRedirect(route('login'));
    }
}

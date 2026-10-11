<?php

namespace Tests\Feature;

use App\Http\Controllers\Auth\LoginController;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Delivery lives in the Melai Nuts app only (owner / staff create and dispatch runs, riders
 * deliver, customers track). The website has no delivery page, menu entry, JSON endpoint or
 * action, and riders cannot sign in to it. Delivery orders still appear as a read-only sale.
 */
class NoDeliveryOnWebsiteTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    public function test_the_sidebar_has_no_deliveries_or_driver_tracking(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        foreach (['/dashboard', '/orders', '/admin/users', '/help', '/settings'] as $url) {
            $this->signedIn($owner)->get($url)->assertOk()
                ->assertDontSee('Driver tracking')->assertDontSee('Driver Tracking')
                ->assertDontSee('>Deliveries<', false)->assertDontSee('s/deliveries')->assertDontSee('s/driver-tracking')
                ->assertDontSee('drivers.json')->assertDontSee('leaflet', false)->assertDontSee('driverMap', false);
        }
        $this->assertArrayNotHasKey('deliveries', config('melai.sections'));
        $this->assertArrayNotHasKey('driver-tracking', config('melai.sections'));
    }

    public function test_the_old_delivery_urls_are_not_found(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');

        foreach (['/s/deliveries', '/s/driver-tracking', '/dashboard/drivers.json'] as $url) {
            $this->signedIn($owner)->get($url)->assertNotFound();      // not a redirect, not an empty page
            $this->signedIn($owner)->getJson($url)->assertNotFound();
        }
    }

    public function test_a_delivery_order_cannot_be_advanced_from_the_website(): void
    {
        $this->useFakeSupabase();
        $this->db->orders[0]['is_delivery'] = true;
        $owner = $this->linkedLogin('uid-owner');
        $id = $this->db->orders[0]['id'];

        foreach (['pending', 'confirmed', 'preparing', 'outForDelivery'] as $status) {
            $this->db->orders[0]['status'] = $status;
            app(\App\Services\OrderQueryService::class)->refresh();
            $this->signedIn($owner)->postJson("/orders/$id/advance", ['from' => $status])
                ->assertStatus(422)->assertJsonPath('order.next', null)->assertJsonPath('order.status', $status);
        }
        $this->assertNotContains('staff_update_order_status', $this->db->calledFunctions());

        // The Orders list shows it read-only: a channel label, no "next stage".
        $row = collect($this->signedIn($owner)->get('/orders')->assertOk()->viewData('orders'))->firstWhere('id', $id);
        $this->assertTrue($row['isDelivery']);
        $this->assertNull($row['next']);
        $this->assertArrayNotHasKey('expected', $row);
    }

    public function test_a_delivery_order_cannot_be_created_from_the_website(): void
    {
        $this->useFakeSupabase();
        $owner = $this->linkedLogin('uid-owner');
        $line = ['variant_id' => '11111111-1111-4111-8111-111111111111', 'quantity' => 1];
        $base = ['branch' => 'b-cal', 'items' => [$line], 'method' => 'cash', 'cash_received' => 200, 'key' => 'k-delivery'];

        foreach ([['type' => 'delivery'], ['is_delivery' => true], ['delivery_address_id' => '22222222-2222-4222-8222-222222222222'],
            ['delivery_address' => '1 Pin St, Calamba'], ['fulfillment' => 'delivery'], ['order_type' => 'delivery']] as $extra) {
            $this->signedIn($owner)->postJson('/orders', $base + $extra)->assertStatus(422)->assertJsonValidationErrors(array_keys($extra));
        }
        $this->assertNotContains('staff_create_pos_sale', $this->db->calledFunctions());
        $this->assertNotContains('place_order', $this->db->calledFunctions());
    }

    public function test_a_driver_login_cannot_sign_in_to_the_website(): void
    {
        (new \Tests\Support\FakeFirebase)->install(); // no app account for this e-mail: falls back to the website password
        // An old website rider login is kept in the table (never deleted) but refused.
        $rider = User::factory()->create(['email' => 'rider@example.com', 'password' => 'Rider#Pass1', 'role' => 'driver', 'has_access' => true]);

        $this->post('/login', ['email' => 'rider@example.com', 'password' => 'Rider#Pass1'])->assertSessionHasErrors('auth');
        $this->assertGuest();
        $this->assertSame(LoginController::APP_ONLY_MESSAGE, session('errors')->first('auth'));
        $this->assertDatabaseHas('users', ['id' => $rider->id, 'role' => 'driver']);

        // A session left over from before is ended on the next request.
        $this->actingAs($rider)->get('/dashboard')->assertRedirect(route('login'));
        $this->assertGuest();

        // ...and the role middleware never lets it through either.
        $this->assertFalse($rider->canUseWebsite());
        $this->assertTrue(User::factory()->make(['role' => 'staff'])->canUseWebsite());
        $this->assertTrue(User::factory()->make(['role' => 'admin'])->canUseWebsite());
    }

    public function test_a_driver_role_cannot_be_registered_or_created(): void
    {
        $admin = User::factory()->create(['role' => 'admin', 'has_access' => true]);
        $this->actingAs($admin)->post('/admin/users', ['name' => 'Rider', 'email' => 'new-rider@example.com', 'role' => 'driver',
            'password' => 'Rider#Pass1', 'password_confirmation' => 'Rider#Pass1'])->assertSessionHasErrors('role');
        $this->assertNull(User::firstWhere('email', 'new-rider@example.com'));
        $this->actingAs($admin)->get('/admin/users/create')->assertOk()->assertDontSee('value="driver"', false);
    }
}

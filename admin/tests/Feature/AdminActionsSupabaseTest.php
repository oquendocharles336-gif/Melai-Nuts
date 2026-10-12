<?php

namespace Tests\Feature;

use App\Exceptions\BackendActionException;
use App\Services\Supabase\SupabaseGateway;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\FakeSupabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * The redesigned UI's write actions call the app's own staff functions (staff_update_order_status,
 * staff_receive_batch, staff_create_pos_sale) as the signed-in account, and the Overview / badges
 * re-read the database afterwards. FakeSupabase is extended here with those three functions.
 */
class AdminActionsSupabaseTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private function fake(): FakeSupabase
    {
        $this->useFakeSupabase();
        $base = $this->db;
        $fake = new class extends FakeSupabase {
            public function call(string $firebaseUid, string $sql, array $bindings = [], array $verified = []): mixed
            {
                preg_match('/public\.(\w+)\(/', $sql, $m);
                $fn = $m[1] ?? '';
                $me = $this->staff[$firebaseUid] ?? null;
                $allowed = ($me['role'] ?? null) === 'owner' ? array_column($this->branches, 'id') : [$me['branch_id'] ?? null];
                switch ($fn) {
                    case 'staff_update_order_status':
                        $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];
                        foreach ($this->orders as &$o) {
                            if ($o['id'] === $bindings[0]) {
                                if (! in_array($o['branch_id'], $allowed, true)) {
                                    throw new BackendActionException('You can only work in your assigned branch.');
                                }
                                $o['status'] = $bindings[1];
                            }
                        }
                        return null;
                    case 'staff_get_inventory':
                        $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];
                        return ['branch_id' => $bindings[0], 'items' => [['product_id' => 'p1', 'product_name' => 'Garlic Peanuts', 'variant_id' => '11111111-1111-4111-8111-111111111111',
                            'variant_label' => 'Regular', 'sku' => 'GP', 'price' => 90, 'quantity' => 3 + (int) ($this->received ?? 0), 'restock_threshold' => 10, 'batched_quantity' => 3]]];
                    case 'staff_receive_batch':
                        $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];
                        $this->received = (int) $bindings[3];
                        return 'batch-1';
                    case 'staff_create_pos_sale':
                        $this->calls[] = ['uid' => $firebaseUid, 'fn' => $fn, 'bindings' => $bindings, 'claims' => $verified];
                        // Like the database: the same key + same details answers with the recorded sale.
                        return ['order_id' => 'POS-1', 'total' => 180, 'change' => 20,
                            'already_recorded' => str_ends_with((string) ($bindings[5] ?? ''), 'replay')];
                }

                return parent::call($firebaseUid, $sql, $bindings, $verified);
            }
            public ?int $received = null;
        };
        foreach (['branches', 'staff', 'orders', 'stock', 'activity'] as $p) {
            $fake->{$p} = $base->{$p};
        }
        $this->db = $fake;
        $this->app->instance(SupabaseGateway::class, $fake);

        return $fake;
    }

    public function test_owner_moves_an_order_to_its_next_stage_through_the_app_function(): void
    {
        $db = $this->fake();
        $db->orders[0]['status'] = 'preparing';
        $db->orders[0]['is_delivery'] = false; // pickup
        $owner = $this->linkedLogin('uid-owner');

        $res = $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'preparing'])->assertOk();
        $this->assertSame('readyForPickup', $res->json('order.status'));
        $this->assertSame('shipped', $res->json('order.stage'));
        $this->assertSame('completed', $res->json('order.next'));
        $call = collect($db->calls)->firstWhere('fn', 'staff_update_order_status');
        $this->assertSame(['ORD-CAL-1', 'readyForPickup', null], $call['bindings']);
        $this->assertSame('uid-owner', $call['uid']);
    }

    public function test_a_delivery_order_is_never_moved_by_the_website(): void
    {
        $db = $this->fake();
        $db->orders[0]['status'] = 'preparing';
        $db->orders[0]['is_delivery'] = true;
        $owner = $this->linkedLogin('uid-owner');

        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'preparing'])
            ->assertStatus(422)->assertJsonPath('order.status', 'preparing')->assertJsonPath('order.next', null);
        $this->assertNotContains('staff_update_order_status', $db->calledFunctions());
    }

    public function test_a_stale_screen_does_not_skip_a_step_and_staff_stay_in_their_branch(): void
    {
        $db = $this->fake();
        $db->orders[0]['status'] = 'confirmed';
        $owner = $this->linkedLogin('uid-owner');
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'pending'])->assertStatus(409)->assertJsonPath('order.status', 'confirmed');
        $this->assertNotContains('staff_update_order_status', $db->calledFunctions());

        $db->orders[1]['status'] = 'pending';
        $lb = 'ORD-LB-1';
        $cora = $this->linkedLogin('uid-cal');
        $this->signedIn($cora)->postJson("/orders/$lb/advance", ['from' => 'pending'])->assertNotFound(); // not her branch
        $this->signedIn($cora)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'completed'])->assertStatus(409);
    }

    public function test_receive_stock_posts_a_batch_and_returns_the_database_row(): void
    {
        $db = $this->fake();
        $owner = $this->linkedLogin('uid-owner');
        $body = ['branch' => 'b-cal', 'variant_id' => '11111111-1111-4111-8111-111111111111', 'quantity' => 24,
            'batch_code' => 'WEB-1', 'expiration_date' => now()->addMonths(6)->toDateString()];

        $this->signedIn($owner)->postJson('/stock/receive', ['expiration_date' => now()->subDay()->toDateString()] + $body)->assertStatus(422);
        $this->signedIn($owner)->postJson('/stock/receive', ['branch' => 'not-mine'] + $body)->assertStatus(422);
        $this->assertNotContains('staff_receive_batch', $db->calledFunctions());

        $this->signedIn($owner)->postJson('/stock/receive', $body)->assertOk()->assertJsonPath('item.quantity', 27);
        $call = collect($db->calls)->firstWhere('fn', 'staff_receive_batch');
        $this->assertSame(['b-cal', $body['variant_id'], 'WEB-1', 24, $body['expiration_date']], $call['bindings']);
    }

    public function test_new_order_records_a_pos_sale(): void
    {
        $db = $this->fake();
        $owner = $this->linkedLogin('uid-owner');
        $line = ['variant_id' => '11111111-1111-4111-8111-111111111111', 'quantity' => 2];

        $this->signedIn($owner)->getJson('/orders/catalog.json?branch=b-cal')->assertOk()->assertJsonPath('0.price', 90);
        $this->signedIn($owner)->postJson('/orders', ['branch' => 'b-cal', 'items' => [$line], 'method' => 'gcash', 'key' => 'k1'])->assertStatus(422); // reference needed
        $this->signedIn($owner)->postJson('/orders', ['branch' => 'b-cal', 'items' => [$line], 'method' => 'cash', 'cash_received' => 200, 'key' => 'k1'])
            ->assertOk()->assertJsonPath('result.order_id', 'POS-1');
        $call = collect($db->calls)->firstWhere('fn', 'staff_create_pos_sale');
        $this->assertSame('b-cal', $call['bindings'][0]);
        $this->assertSame([$line], json_decode($call['bindings'][1], true));
        $this->assertSame('cash', $call['bindings'][2]);
        $this->assertSame('web:k1', $call['bindings'][5]);
    }

    public function test_a_replayed_pos_sale_says_it_was_already_recorded(): void
    {
        $this->fake();
        $owner = $this->linkedLogin('uid-owner');
        $body = ['branch' => 'b-cal', 'items' => [['variant_id' => '11111111-1111-4111-8111-111111111111', 'quantity' => 2]],
            'method' => 'cash', 'cash_received' => 200];

        $this->signedIn($owner)->postJson('/orders', $body + ['key' => 'k-first'])
            ->assertOk()->assertJsonPath('already_recorded', false)->assertJsonPath('message', 'Order POS-1 recorded.');
        $this->signedIn($owner)->postJson('/orders', $body + ['key' => 'k-replay'])
            ->assertOk()->assertJsonPath('already_recorded', true)
            ->assertJsonPath('message', 'This sale was already recorded as order POS-1. It was not charged twice.');
    }

    public function test_overview_and_badges_follow_a_change_immediately(): void
    {
        $db = $this->fake();
        config(['melai.dashboard.cache_seconds' => 45]);
        $db->orders[0]['status'] = 'pending';
        $owner = $this->linkedLogin('uid-owner');

        $this->assertSame(1, $this->signedIn($owner)->getJson('/ui/counts.json')->assertOk()->json('orders'));
        $this->assertSame(1, $this->signedIn($owner)->getJson('/dashboard/overview.json?range=7')->assertOk()->json('pipeline.counts.new'));

        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'pending'])->assertOk(); // -> confirmed (still "New")
        $this->signedIn($owner)->postJson('/orders/ORD-CAL-1/advance', ['from' => 'confirmed'])->assertOk(); // -> preparing
        // Cached for 45 s, but every action bumps the cache version: the next read is fresh.
        $this->assertSame(1, $this->signedIn($owner)->getJson('/dashboard/overview.json?range=7')->json('pipeline.counts.packing'));
        $this->assertSame(1, $this->signedIn($owner)->getJson('/ui/counts.json')->json('orders'));
    }
}

<?php

namespace App\Services;

use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseGateway;
use Illuminate\Support\Facades\Cache;

/**
 * The three write actions of the redesigned admin UI, each one an EXISTING staff function of the
 * Melai Nuts app (the same ones the mobile app calls), executed AS the signed-in user's linked
 * staff account through SupabaseGateway::call(). Supabase decides whether the account may do it
 * (branch scope, 'inventory' permission, order state machine, stock checks); nothing is written
 * locally and no rule is re-implemented here.
 *
 *  - staff_update_order_status(order_id, status, note)   Orders drawer: "Move to next stage"
 *    (pickup and in-store orders only: delivery orders are handled in the app, see nextStatus)
 *  - staff_receive_batch(branch, variant, code, qty, …)  Stock: "Receive stock"
 *  - staff_create_pos_sale(branch, items, method, …)     "New order" (walk-in / in-store sale)
 *
 * After every successful action the UI cache version for this login is bumped, so the Overview,
 * the pipeline and the sidebar badges re-read the database instead of showing cached numbers.
 */
class AdminActions
{
    public function __construct(private SupabaseGateway $gateway, private StaffIdentity $identity) {}

    /**
     * The order workflow of the app (enforce_order_transition), one step at a time, for pickup and
     * in-store orders. Delivery orders have NO next stage on the website: confirming, packing,
     * dispatching and completing them happens only in the Melai Nuts app (staff portal and delivery
     * runs), so the website can never move an order into or through delivery.
     */
    public static function nextStatus(string $status, bool $isDelivery): ?string
    {
        if ($isDelivery) {
            return null;
        }

        return match ($status) {
            'pending' => 'confirmed',
            'confirmed' => 'preparing',
            'preparing' => 'readyForPickup',
            'readyForPickup' => 'completed',
            default => null, // completed, cancelled, refund states: no "next stage" from here
        };
    }

    public function updateOrderStatus(string $orderId, string $status, ?string $note = null): void
    {
        $this->gateway->call($this->identity->uid(), 'select public.staff_update_order_status(?::text, ?::text, ?::text)::text as r',
            [$orderId, $status, $note]);
        self::bump();
    }

    /** Returns the new batch id. */
    public function receiveBatch(string $branchId, string $variantId, string $batchCode, int $quantity, string $expirationDate): ?string
    {
        $id = $this->gateway->call($this->identity->uid(),
            'select to_jsonb(public.staff_receive_batch(?::uuid, ?::uuid, ?::text, ?::int, ?::date, null::date, null::int, false))::text as r',
            [$branchId, $variantId, $batchCode, $quantity, $expirationDate]);
        self::bump();

        return is_string($id) ? $id : null;
    }

    /** $items: [['variant_id' => uuid, 'quantity' => int], ...]. Returns ['order_id', 'total', 'change', ...]. */
    public function createPosSale(string $branchId, array $items, string $method, ?string $reference, ?float $cashReceived, string $idempotencyKey): array
    {
        $r = $this->gateway->call($this->identity->uid(),
            'select public.staff_create_pos_sale(?::uuid, ?::jsonb, ?::text, ?::text, ?::numeric, null::text, ?::text)::text as r',
            [$branchId, json_encode(array_values($items), JSON_THROW_ON_ERROR), $method, $reference, $cashReceived, $idempotencyKey]) ?? [];
        self::bump();

        return $r;
    }

    // ---- data version (one for the whole site) ----------------------------------------------

    /**
     * Part of every cache key (App\Support\Swr, OverviewService). Bumped after EVERY successful
     * change (these actions, and every mutating route through the "bumps.cache" middleware), so no
     * account is served data from before the change. Kept forever in the cache store.
     */
    public static function version(): int
    {
        return (int) Cache::get(self::VERSION_KEY, 0);
    }

    public static function bump(): void
    {
        if (! Cache::add(self::VERSION_KEY, 1)) {
            Cache::increment(self::VERSION_KEY);
        }
        app(OrderQueryService::class)->refresh();
    }

    private const VERSION_KEY = 'melai:data-version';
}

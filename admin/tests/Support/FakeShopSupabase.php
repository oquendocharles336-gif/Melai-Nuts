<?php

namespace Tests\Support;

use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;

/**
 * Stands in for the Supabase public API the shop uses (REST tables, RPCs and Edge Functions),
 * with a little state so a test can follow a cart through checkout. Test fixtures only: the shop
 * itself has no data of its own.
 *
 * Every request is recorded with the bearer token it carried, so tests can prove that customer
 * data was read and written AS the customer (their Firebase ID token), never with the anon key.
 */
class FakeShopSupabase
{
    public const URL = 'https://shop-project.supabase.test';

    public const ANON = 'anon-public-key';

    public array $calls = [];

    public array $categories = [['id' => 'cat-1', 'label' => 'Flavored Nuts', 'sort_order' => 1, 'is_active' => true]];

    public array $branches = [
        ['id' => 'br-1', 'name' => 'Santa Cruz Branch', 'address' => 'P. Guevarra St, Santa Cruz', 'is_active' => true, 'contact_phone' => '0495011234',
            'operating_hours' => 'Mon–Sat 8am–6pm', 'supports_delivery' => false, 'supports_pickup' => true, 'delivery_fee' => 0,
            'latitude' => 14.28, 'longitude' => 121.41, 'is_warehouse' => false],
    ];

    public array $products = [
        ['id' => 'p-1', 'name' => 'Chili Garlic Peanuts', 'category_id' => 'cat-1', 'price' => 110, 'original_price' => null, 'description' => 'Spicy and garlicky.',
            'badge' => null, 'images' => [], 'tags' => ['spicy'], 'is_featured' => true, 'is_active' => true],
        ['id' => 'p-2', 'name' => 'Roasted Cashew', 'category_id' => 'cat-1', 'price' => 220, 'original_price' => null, 'description' => '',
            'badge' => null, 'images' => [], 'tags' => [], 'is_featured' => false, 'is_active' => true],
    ];

    public array $variants = [
        ['id' => 'v-1', 'product_id' => 'p-1', 'label' => '100g', 'price' => 110, 'sort_order' => 1, 'is_active' => true],
        ['id' => 'v-2', 'product_id' => 'p-2', 'label' => '250g', 'price' => 220, 'sort_order' => 1, 'is_active' => true],
    ];

    /** branch_id => variant_id => quantity */
    public array $stock = ['br-1' => ['v-1' => 10, 'v-2' => 3]];

    /** uid => branch_id => ['items' => [...], 'voucher_code' => ?, 'redeem_points' => bool] */
    public array $carts = [];

    public array $profiles = [];

    public array $orders = [];

    public bool $onlinePayment = true;

    /** cod_downpayment_quote answer (required = false: no downpayment). */
    public array $quote = ['required' => false, 'amount' => 0, 'balance' => 0];

    /** first_order_quote answer (first_order = false: a returning customer; null = the call fails). */
    public ?array $firstOrder = ['first_order' => false];

    /** The customer's mobile number is verified (first_order_quote's phone_verified). */
    public bool $phoneVerified = true;

    /** email-verification: uids a code was sent to, and the code the fake accepts. */
    public array $codesSent = [];

    public string $acceptedCode = '123456';

    /** Called with the uid when the right code is entered (the test marks the Firebase account verified). */
    public ?\Closure $onEmailVerified = null;

    public array $legal = [];

    public array $paymentRequests = [];

    /** cart_id => [uid, branch_id] */
    private array $cartIds = [];

    public function install(): self
    {
        config(['melai.shop.supabase_url' => self::URL, 'melai.shop.anon_key' => self::ANON, 'melai.shop.catalog_cache_seconds' => 0]);

        Http::fake([self::URL.'/*' => fn (Request $r) => $this->handle($r)]);

        return $this;
    }

    /** Requests to $path made with a customer token (not the anon key). */
    public function asCustomer(string $path): array
    {
        return array_values(array_filter($this->calls, fn ($c) => str_contains($c['path'], $path) && $c['token'] !== self::ANON));
    }

    public function called(string $path): array
    {
        return array_values(array_filter($this->calls, fn ($c) => str_contains($c['path'], $path)));
    }

    private function handle(Request $r)
    {
        $path = (string) parse_url($r->url(), PHP_URL_PATH);
        $token = substr((string) ($r->header('Authorization')[0] ?? ''), 7);
        parse_str((string) parse_url($r->url(), PHP_URL_QUERY), $query);
        $body = $r->data();
        $this->calls[] = ['method' => $r->method(), 'path' => $path, 'token' => $token, 'query' => $query, 'body' => $body];
        $uid = $token === self::ANON ? null : $this->uid($token);
        $this->lastToken = $token;

        if (str_starts_with($path, '/functions/v1/')) {
            return $this->function(substr($path, 14), $body, $uid);
        }
        if (str_starts_with($path, '/rest/v1/rpc/')) {
            return $this->rpc(substr($path, 13), $body, $uid);
        }

        return $this->table(substr($path, 9), $r->method(), $query, $body, $uid);
    }

    private function table(string $table, string $method, array $q, array $body, ?string $uid)
    {
        $eq = fn (string $k) => isset($q[$k]) && str_starts_with($q[$k], 'eq.') ? substr($q[$k], 3) : null;
        $in = fn (string $k) => isset($q[$k]) && str_starts_with($q[$k], 'in.(') ? explode(',', trim(substr($q[$k], 3), '()')) : null;

        return match ($table) {
            'product_categories' => Http::response($this->categories),
            'branches' => Http::response($this->branches),
            'products' => Http::response($this->products),
            'product_variants' => Http::response(array_values(array_filter($this->variants, fn ($v) => ($in('product_id') ?? [$v['product_id']]) !== null && in_array($v['product_id'], $in('product_id') ?? [$v['product_id']], true)))),
            'branch_inventory' => Http::response($this->inventory($eq('branch_id'), $in('variant_id'))),
            'payment_settings' => Http::response([['online_payment_enabled' => $this->onlinePayment, 'online_payment_disabled_message' => 'Online payment is paused.']]),
            'customer_profiles' => $this->profilesTable($method, $eq('firebase_uid'), $body, $uid),
            'orders' => Http::response(array_values(array_filter($this->orders, fn ($o) => $o['firebase_uid'] === $uid && ($eq('id') === null || $o['id'] === $eq('id'))))),
            'loyalty_accounts' => Http::response([['points_balance' => 120]]),
            'loyalty_transactions' => Http::response([['id' => 't1', 'points' => 120, 'type' => 'earn', 'description' => 'Order ORD-1', 'order_id' => 'ORD-1', 'created_at' => '2026-11-01T10:00:00Z']]),
            default => Http::response(['message' => 'unknown table '.$table], 404),
        };
    }

    private function inventory(?string $branch, ?array $variants): array
    {
        $rows = [];
        foreach ($this->stock as $b => $byVariant) {
            if ($branch !== null && $b !== $branch) {
                continue;
            }
            foreach ($byVariant as $v => $qty) {
                if ($variants !== null && ! in_array($v, $variants, true)) {
                    continue;
                }
                $product = collect($this->variants)->firstWhere('id', $v)['product_id'] ?? null;
                $rows[] = ['branch_id' => $b, 'product_id' => $product, 'variant_id' => $v, 'quantity' => $qty, 'is_carried' => true];
            }
        }

        return $rows;
    }

    private function profilesTable(string $method, ?string $filterUid, array $body, ?string $uid)
    {
        if ($uid === null) {
            return Http::response(['message' => 'permission denied', 'code' => '42501'], 401);
        }
        if ($method === 'POST') {
            $this->profiles[$uid] = $body;

            return Http::response([$body], 201);
        }
        if ($method === 'PATCH') {
            $this->profiles[$uid] = array_merge($this->profiles[$uid] ?? ['firebase_uid' => $uid], $body);

            return Http::response([$this->profiles[$uid]]);
        }

        return Http::response(isset($this->profiles[$uid]) && $filterUid === $uid ? [$this->profiles[$uid]] : []);
    }

    private string $lastToken = '';

    /** Verified numbers per uid (claim_verified_phone). */
    public array $verifiedPhones = [];

    /** claim_verified_phone: the number comes from the token's phone_number claim, like the database. */
    private function claimPhone(?string $uid)
    {
        $parts = explode('.', $this->lastToken);
        $claims = json_decode(base64_decode(strtr($parts[1] ?? '', '-_', '+/')), true) ?: [];
        $phone = (string) ($claims['phone_number'] ?? '');
        if ($uid === null || $phone === '') {
            return Http::response(['code' => 'P0001', 'message' => 'Please verify your mobile number with the SMS code first.'], 400);
        }
        foreach ($this->verifiedPhones as $other => $p) {
            if ($p === $phone && $other !== $uid) {
                return Http::response(['code' => 'P0001', 'message' => 'This mobile number is already verified on another Melai Nuts account. Sign in to that account, or verify a different number.'], 400);
            }
        }
        $this->verifiedPhones[$uid] = $phone;
        $this->phoneVerified = true;

        return Http::response(['verified_phone' => $phone, 'first_order' => true]);
    }

    private function rpc(string $fn, array $p, ?string $uid)
    {
        return match ($fn) {
            'get_popular_products' => Http::response([['product_id' => 'p-2', 'total_quantity' => 9]]),
            'get_storefront_settings' => Http::response(['low_stock_badge_qty' => 3]),
            'get_customer_cart' => Http::response($this->cartState($uid, (string) $p['p_branch_id'])),
            'sync_customer_cart' => $this->sync($uid, $p),
            'register_voucher_attempt' => Http::response(null),
            'cod_downpayment_quote' => Http::response($this->quote),
            // A customer whose mobile number is verified unless the test says otherwise (migration 20261118040000).
            'first_order_quote' => $this->firstOrder === null ? Http::response(['message' => 'unavailable'], 503)
                : Http::response($this->firstOrder + ['phone_verified' => $this->phoneVerified, 'phone_claimable' => false,
                    'verified_phone' => $this->phoneVerified ? '+639171234567' : null]),
            'my_legal_acceptance' => Http::response($this->legal[$uid] ?? ['terms_version' => null, 'privacy_version' => null]),
            'accept_legal_terms' => $this->accept($uid, $p),
            'place_order' => $this->place($uid, $p),
            'claim_verified_phone' => $this->claimPhone($uid),
            default => Http::response(['message' => 'unknown function '.$fn, 'code' => '42883'], 404),
        };
    }

    private function cartState(?string $uid, string $branch): ?array
    {
        $cart = $this->carts[$uid][$branch] ?? null;
        if ($cart === null) {
            return null;
        }
        $items = array_map(function ($i) {
            $v = collect($this->variants)->firstWhere('id', $i['variant_id']);

            return $i + ['variant_label' => $v['label'] ?? '', 'current_price' => $v['price'] ?? 0];
        }, $cart['items']);
        $subtotal = array_sum(array_map(fn ($i) => $i['current_price'] * $i['quantity'], $items));

        $cartId = 'cart-'.md5($uid.'|'.$branch);
        $this->cartIds[$cartId] = [$uid, $branch];

        return ['cart_id' => $cartId, 'branch_id' => $branch, 'voucher_code' => $cart['voucher_code'], 'redeem_points' => $cart['redeem_points'],
            'items' => $items, 'pricing' => ['subtotal' => $subtotal, 'voucher_discount' => 0, 'loyalty_discount' => 0, 'delivery_fee' => 0, 'total' => $subtotal,
                'loyalty_points_balance' => 120, 'loyalty_points_used' => 0]];
    }

    private function sync(?string $uid, array $p)
    {
        foreach ($p['p_items'] as $i) {
            if (($this->stock[$p['p_branch_id']][$i['variant_id']] ?? 0) < $i['quantity']) {
                return Http::response(['message' => 'Only '.($this->stock[$p['p_branch_id']][$i['variant_id']] ?? 0).' left at this branch.', 'code' => 'P0001'], 400);
            }
        }
        $this->carts[$uid][$p['p_branch_id']] = ['items' => array_values($p['p_items']), 'voucher_code' => $p['p_voucher_code'] ?? null, 'redeem_points' => (bool) ($p['p_redeem_points'] ?? false)];

        return Http::response($this->cartState($uid, $p['p_branch_id']));
    }

    private function accept(?string $uid, array $p)
    {
        $this->legal[$uid] = ['terms_version' => $p['p_terms_version'], 'privacy_version' => $p['p_privacy_version']];

        return Http::response($this->legal[$uid]);
    }

    private function place(?string $uid, array $p)
    {
        foreach ($this->orders as $o) {
            if ($o['_key'] === $p['p_idempotency_key']) {
                return Http::response(json_encode($o['id']), 200, ['Content-Type' => 'application/json']);   // same request again: the first order
            }
        }
        [$owner, $branch] = $this->cartIds[$p['p_cart_id']] ?? [null, null];
        if ($owner !== $uid) {
            return Http::response(['message' => 'Your cart could not be found.', 'code' => 'P0001'], 400);
        }
        $state = $this->cartState($uid, $branch);
        $id = 'ORD-'.(1001 + count($this->orders));
        $downpayment = $this->quote['required'] && $p['p_payment_method'] === 'Cash on Counter Pickup';
        $this->orders[] = [
            '_key' => $p['p_idempotency_key'], '_params' => $p,
            'id' => $id, 'firebase_uid' => $uid, 'branch_id' => 'br-1', 'branch_name' => 'Santa Cruz Branch', 'is_delivery' => $p['p_is_delivery'],
            'status' => $downpayment ? 'awaitingDownpayment' : 'pending', 'subtotal' => $state['pricing']['subtotal'] ?? 0, 'discount' => 0, 'delivery_fee' => 0,
            'total' => $state['pricing']['total'] ?? 0, 'payment_method' => $p['p_payment_method'], 'points_earned' => 0, 'created_at' => '2026-11-08T05:00:00Z',
            'updated_at' => '2026-11-08T05:00:00Z', 'customer_notes' => $p['p_customer_notes'], 'contact_phone' => null,
            'order_items' => array_map(fn ($i) => ['id' => 'oi', 'product_name' => 'Item', 'variant_label' => $i['variant_label'], 'quantity' => $i['quantity'], 'unit_price' => $i['current_price'], 'product_id' => $i['product_id'], 'variant_id' => $i['variant_id']], $state['items'] ?? []),
            'order_status_events' => [['id' => 'e1', 'status' => $downpayment ? 'awaitingDownpayment' : 'pending', 'note' => '', 'created_at' => '2026-11-08T05:00:00Z']],
            'payments' => [['id' => 'pay-1', 'method' => $p['p_payment_method'] === 'Cash on Counter Pickup' ? 'cash' : 'online', 'status' => 'pending', 'amount' => $state['pricing']['total'] ?? 0]],
            'order_downpayments' => $downpayment ? [['amount' => $this->quote['amount'], 'status' => 'pending', 'expires_at' => '2026-11-08T05:30:00Z', 'percent' => 30, 'pickup_days' => 2]] : [],
        ];
        unset($this->carts[$uid]);

        // PostgREST answers a text-returning function with a JSON string.
        return Http::response(json_encode($id), 200, ['Content-Type' => 'application/json']);
    }

    /** Like the Edge Function: a captcha token is required (the website has no App Check). */
    private function sendCode(string $uid, array $body)
    {
        if (($body['captcha_token'] ?? '') === '') {
            return Http::response(['error' => 'Please complete the security check.', 'code' => 'captcha_required'], 428);
        }
        $this->codesSent[] = $uid;

        return Http::response(['sent' => true, 'expires_in' => 600, 'resend_after' => 60]);
    }

    private function verifyCode(string $uid, array $body)
    {
        if (($body['captcha_token'] ?? '') === '') {
            return Http::response(['error' => 'Please complete the security check.', 'code' => 'captcha_required'], 428);
        }
        if (($body['code'] ?? '') !== $this->acceptedCode) {
            return Http::response(['error' => 'That code is incorrect.', 'code' => 'wrong_code', 'attempts_left' => 4], 400);
        }
        if ($this->onEmailVerified !== null) {
            ($this->onEmailVerified)($uid);
        }

        return Http::response(['verified' => true]);
    }

    private function function(string $name, array $body, ?string $uid)
    {
        if ($uid === null) {
            return Http::response(['error' => 'Please sign in again.'], 401);
        }

        return match ($name) {
            'grant-role-claim' => Http::response(['ok' => true]),
            'hitpay-create-payment' => $this->paymentRequest($body),
            'email-verification/send-code' => $this->sendCode($uid, $body),
            'email-verification/verify-code' => $this->verifyCode($uid, $body),
            default => Http::response(['error' => 'unknown function'], 404),
        };
    }

    private function paymentRequest(array $body)
    {
        $this->paymentRequests[] = $body;

        return Http::response(['checkout_url' => 'https://securecheckout.sandbox.hit-pay.com/payment-request/'.$body['order_id']]);
    }

    private function uid(string $jwt): ?string
    {
        $p = json_decode((string) base64_decode(strtr(explode('.', $jwt)[1] ?? '', '-_', '+/')), true);

        return is_array($p) ? ($p['sub'] ?? null) : null;
    }
}

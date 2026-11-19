<?php

namespace App\Services\Shop;

use Illuminate\Support\Str;

/**
 * Checkout, orders, payment and points for the signed-in customer, through the same database
 * functions and tables as the app: place_order (store pickup only), cod_downpayment_quote (the
 * downpayment rule decided by the server), first_order_quote (a first order pays 50% or 100%
 * online first, migration 20261118015010), hitpay-create-payment (HitPay checkout), orders,
 * loyalty_accounts and loyalty_transactions. Orders land in the same tables as app orders, so
 * staff and owners see them like any other order.
 */
class ShopOrders
{
    /** The app's payment labels (checkout_screen.dart); the database knows them by these names. */
    public const PAY_ONLINE = 'Online Payment (GCash, QR Ph, Card)';

    public const PAY_AT_COUNTER = 'Cash on Counter Pickup';

    private const ATTEMPT = 'shop_checkout_attempt';

    private const ORDER_SELECT = 'id,branch_id,branch_name,is_delivery,status,subtotal,discount,delivery_fee,total,payment_method,points_earned,created_at,updated_at,customer_notes,contact_phone,'
        .'order_items(id,product_name,variant_label,quantity,unit_price,product_id,variant_id),'
        .'order_status_events(id,status,note,created_at),'
        .'payments(id,method,status,amount,reference_number,gateway,created_at,updated_at),'
        .'order_downpayments(amount,status,expires_at,percent,pickup_days,kind,choice)';

    public const STATUS_LABELS = [
        'awaitingDownpayment' => 'Awaiting online payment',
        'pending' => 'Placed',
        'confirmed' => 'Confirmed',
        'preparing' => 'Preparing',
        'readyForPickup' => 'Ready for pickup',
        'outForDelivery' => 'Out for delivery',
        'completed' => 'Completed',
        'cancelled' => 'Cancelled',
        'refundRequested' => 'Refund requested',
        'refunded' => 'Refunded',
    ];

    public function __construct(private CustomerSession $customer, private SupabaseRest $rest) {}

    /**
     * `read` is false when the switch could not be read: only a switch read as off pauses
     * ordering (place_order decides either way).
     *
     * @return array{enabled: bool, message: string, read: bool}
     */
    public function onlinePayment(): array
    {
        $read = true;
        try {
            $row = $this->rest->select('payment_settings', ['select' => 'online_payment_enabled,online_payment_disabled_message', 'id' => 'eq.default'], $this->customer->idToken())[0] ?? [];
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }
            $row = [];
            $read = false;
        }
        $message = trim((string) ($row['online_payment_disabled_message'] ?? ''));

        return [
            'enabled' => ($row['online_payment_enabled'] ?? false) === true,
            'message' => $message !== '' ? $message : 'Online payment is not available right now. Please try again later.',
            'read' => $read,
        ];
    }

    /**
     * The downpayment the server will ask for on a pickup order of this total (preview only; the
     * server applies it either way). Null when the preview can't be loaded.
     *
     * @return array{required: bool, amount: float, balance: float, percent: ?float, expiry_minutes: ?int, pickup_days: ?int}|null
     */
    public function downpaymentQuote(float $total): ?array
    {
        try {
            $q = $this->rest->rpc('cod_downpayment_quote', ['p_total' => round($total, 2)], $this->customer->idToken());
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }

            return null;
        }
        if (! is_array($q)) {
            return null;
        }

        return [
            'required' => ($q['required'] ?? false) === true,
            'amount' => (float) ($q['amount'] ?? 0),
            'balance' => (float) ($q['balance'] ?? 0),
            'percent' => isset($q['percent']) ? (float) $q['percent'] : null,
            'expiry_minutes' => isset($q['expiry_minutes']) ? (int) $q['expiry_minutes'] : null,
            'pickup_days' => isset($q['pickup_days']) ? (int) $q['pickup_days'] : null,
        ];
    }

    /**
     * Whether this is the customer's FIRST order (50% or 100% paid online first) and what each
     * choice costs for the server cart. Preview only: place_order decides again. Null when it
     * cannot be loaded (the checkout then offers a retry instead of guessing).
     *
     * @return array{first_order: bool, total: float, half_amount: float, half_balance: float, full_amount: float, expiry_minutes: int, pending_order_id: ?string, online_payment_enabled: bool}|null
     */
    public function firstOrderQuote(array $cart): ?array
    {
        if (($cart['cart_id'] ?? null) === null) {
            return null;
        }
        try {
            $q = $this->rest->rpc('first_order_quote', ['p_cart_id' => $cart['cart_id'], 'p_is_delivery' => false], $this->customer->idToken());
        } catch (ShopException $e) {
            if ($e->sessionEnded()) {
                throw $e;
            }

            return null;
        }
        if (! is_array($q)) {
            return null;
        }

        return [
            'first_order' => ($q['first_order'] ?? false) === true,
            'total' => (float) ($q['total'] ?? 0),
            'half_amount' => (float) ($q['half_amount'] ?? 0),
            'half_balance' => (float) ($q['half_balance'] ?? 0),
            'full_amount' => (float) ($q['full_amount'] ?? 0),
            'expiry_minutes' => (int) ($q['expiry_minutes'] ?? 30),
            'pending_order_id' => is_string($q['pending_order_id'] ?? null) && $q['pending_order_id'] !== '' ? $q['pending_order_id'] : null,
            'online_payment_enabled' => ($q['online_payment_enabled'] ?? false) === true,
        ];
    }

    /**
     * Place a store-pickup order from the server cart. A retry of the identical request (double
     * click, refresh) reuses the same key, so the server returns the first order instead of a second
     * one; any change to the cart or choices makes a new key. $firstOrderPayment ('half' | 'full')
     * is the first-order choice; the server validates it and works the amount out itself.
     */
    public function place(array $cart, string $paymentMethod, string $notes, ?string $firstOrderPayment = null): string
    {
        if (! in_array($paymentMethod, [self::PAY_ONLINE, self::PAY_AT_COUNTER], true)) {
            throw new ShopException('Please choose how you\'ll pay.');
        }
        if ($firstOrderPayment !== null && ! in_array($firstOrderPayment, ['half', 'full'], true)) {
            throw new ShopException('Choose to pay 50% or 100% of your first order now.');
        }
        $parts = [
            $cart['cart_id'], $paymentMethod, $notes, $cart['voucher_code'], $cart['redeem_points'],
            array_map(fn ($l) => $l['variant_id'].'x'.$l['qty'], $cart['lines']),
        ];
        if ($firstOrderPayment !== null) {
            $parts[] = 'first:'.$firstOrderPayment;   // another choice = another request
        }
        $fingerprint = hash('sha256', json_encode($parts));
        $attempt = session(self::ATTEMPT);
        $key = is_array($attempt) && ($attempt['fingerprint'] ?? null) === $fingerprint ? $attempt['key'] : (string) Str::uuid();
        session()->put(self::ATTEMPT, ['fingerprint' => $fingerprint, 'key' => $key]);

        $orderId = $this->rest->rpc('place_order', [
            'p_cart_id' => $cart['cart_id'],
            'p_is_delivery' => false,          // store pickup only, like the app
            'p_delivery_address_id' => null,
            'p_payment_method' => $paymentMethod,
            'p_customer_notes' => $notes,
            'p_idempotency_key' => $key,
        ] + ($firstOrderPayment !== null ? ['p_first_order_payment' => $firstOrderPayment] : []), $this->customer->idToken());
        if (! is_string($orderId) || $orderId === '') {
            throw new ShopException('We couldn\'t confirm your order. Please check My orders before trying again.', 'server');
        }
        session()->forget(self::ATTEMPT);

        return $orderId;
    }

    /**
     * Open HitPay for an unpaid online order or a pickup downpayment. Returns the HitPay checkout URL.
     * The customer comes back to the website's payment page (return_to: web).
     */
    public function startPayment(string $orderId): string
    {
        $data = $this->rest->invoke('hitpay-create-payment', ['order_id' => $orderId, 'return_to' => 'web'], $this->customer->idToken());
        $url = $data['checkout_url'] ?? null;
        if (! is_string($url) || ! str_starts_with($url, 'https://')) {
            throw new ShopException('We couldn\'t open the payment page. Please try again.', 'server');
        }

        return $url;
    }

    /** @return array<int, array<string, mixed>> newest first */
    public function list(int $limit = 50): array
    {
        return array_map(fn ($o) => $this->shape($o), $this->rest->select('orders', [
            'select' => self::ORDER_SELECT,
            'firebase_uid' => 'eq.'.$this->customer->uid(),
            'order' => 'created_at.desc',
            'limit' => $limit,
        ], $this->customer->idToken()));
    }

    public function find(string $orderId): ?array
    {
        $rows = $this->rest->select('orders', [
            'select' => self::ORDER_SELECT,
            'id' => 'eq.'.$orderId,
            'firebase_uid' => 'eq.'.$this->customer->uid(),
        ], $this->customer->idToken());

        return isset($rows[0]) ? $this->shape($rows[0]) : null;
    }

    /** @return array{balance: int, history: array<int, array{points: int, type: string, note: string, created_at: string}>} */
    public function points(): array
    {
        $token = $this->customer->idToken();
        $uid = $this->customer->uid();
        $account = $this->rest->select('loyalty_accounts', ['select' => 'points_balance', 'firebase_uid' => 'eq.'.$uid], $token)[0] ?? [];
        $history = $this->rest->select('loyalty_transactions', ['select' => 'id,points,type,description,order_id,created_at', 'firebase_uid' => 'eq.'.$uid, 'order' => 'created_at.desc', 'limit' => 50], $token);

        return [
            'balance' => (int) ($account['points_balance'] ?? 0),
            'history' => array_map(fn ($t) => [
                'points' => (int) ($t['points'] ?? 0),
                'type' => (string) ($t['type'] ?? ''),
                'note' => (string) ($t['description'] ?? ''),
                'created_at' => (string) ($t['created_at'] ?? ''),
            ], $history),
        ];
    }

    // ------------------------------------------------------------------------------------------

    private function shape(array $o): array
    {
        $payment = $o['payments'][0] ?? (is_array($o['payments'] ?? null) && isset($o['payments']['status']) ? $o['payments'] : null);
        $down = $o['order_downpayments'][0] ?? (is_array($o['order_downpayments'] ?? null) && isset($o['order_downpayments']['status']) ? $o['order_downpayments'] : null);
        $status = (string) ($o['status'] ?? 'pending');
        $events = $o['order_status_events'] ?? [];
        usort($events, fn ($a, $b) => strcmp((string) $a['created_at'], (string) $b['created_at']));
        $online = ($o['payment_method'] ?? '') === self::PAY_ONLINE;
        $paymentStatus = $payment['status'] ?? null;

        return [
            'id' => (string) $o['id'],
            'branch_name' => (string) ($o['branch_name'] ?? ''),
            'branch_id' => $o['branch_id'] ?? null,
            'status' => $status,
            'status_label' => self::STATUS_LABELS[$status] ?? ucfirst($status),
            'subtotal' => (float) ($o['subtotal'] ?? 0),
            'discount' => (float) ($o['discount'] ?? 0),
            'total' => (float) ($o['total'] ?? 0),
            'payment_method' => (string) ($o['payment_method'] ?? ''),
            'payment_status' => $paymentStatus,
            'points_earned' => (int) ($o['points_earned'] ?? 0),
            'created_at' => (string) ($o['created_at'] ?? ''),
            'notes' => (string) ($o['customer_notes'] ?? ''),
            'items' => array_map(fn ($i) => [
                'name' => (string) ($i['product_name'] ?? ''),
                'variant' => (string) ($i['variant_label'] ?? ''),
                'qty' => (int) ($i['quantity'] ?? 0),
                'unit_price' => (float) ($i['unit_price'] ?? 0),
            ], $o['order_items'] ?? []),
            'events' => array_map(fn ($e) => [
                'status' => (string) $e['status'],
                'label' => self::STATUS_LABELS[$e['status']] ?? ucfirst((string) $e['status']),
                'note' => (string) ($e['note'] ?? ''),
                'at' => (string) $e['created_at'],
            ], $events),
            'downpayment' => $down === null ? null : [
                'amount' => (float) ($down['amount'] ?? 0),
                'status' => (string) ($down['status'] ?? ''),
                'expires_at' => $down['expires_at'] ?? null,
                // 'first_order' = the 50% / 100% a first order pays online (choice 'half' | 'full').
                'kind' => (string) ($down['kind'] ?? 'cod'),
                'choice' => $down['choice'] ?? null,
                'balance' => max(0, (float) ($o['total'] ?? 0) - (float) ($down['amount'] ?? 0)),
            ],
            // What the customer can still pay online: a full online order not paid yet, or the online
            // part (pickup downpayment / first order) still due. With an online part, the rest is
            // cash and is never paid here. Only the HitPay webhook marks it paid.
            'can_pay' => ! in_array($status, ['cancelled', 'refunded', 'refundRequested', 'completed'], true) && (
                $down === null
                    ? $online && ! in_array($paymentStatus, ['success', 'refunded'], true)
                    : $status === 'awaitingDownpayment' && in_array($down['status'] ?? '', ['pending', 'failed', 'processing'], true)
            ),
            // A first order paid 50% online: once that half is paid, the rest can be paid online too
            // (or in cash at pickup), migration 20261118040000. The server re-checks all of it.
            'can_pay_balance' => $down !== null && ($down['kind'] ?? '') === 'first_order' && ($down['status'] ?? '') === 'success'
                && ! in_array($status, ['awaitingDownpayment', 'cancelled', 'refunded', 'refundRequested', 'completed'], true)
                && in_array($paymentStatus, ['pending', 'processing', 'failed'], true)
                && (float) ($o['total'] ?? 0) - (float) ($down['amount'] ?? 0) > 0,
            // Fully paid online: an online order, or a first order paid 100% online.
            'paid_online' => $down === null
                ? $online && $paymentStatus === 'success'
                : in_array($down['status'] ?? '', ['success', 'refunded'], true) && (float) ($down['amount'] ?? 0) >= (float) ($o['total'] ?? 0),
        ];
    }
}

<?php

namespace App\Services\Shop;

/**
 * The shop cart.
 *
 * Signed in: the SAME server cart the app uses (get_customer_cart / sync_customer_cart, one cart per
 * customer per branch), so a cart started on the phone shows on the website and the other way round.
 * The server prices it (vouchers, points) and checks stock on every save.
 *
 * Guest: kept in this browser session only, never sent to the server, and added to the customer's
 * own cart when they sign in (capped by live stock), like the app's guest cart.
 */
class ShopCart
{
    public const GUEST = 'shop_guest_cart';

    private const COUNT = 'shop_cart_count';

    public const MAX_QTY = 99;

    public function __construct(
        private CustomerSession $customer,
        private SupabaseRest $rest,
        private ShopCatalog $catalog,
        private ShopBranch $branches,
    ) {}

    /** Item count for the header badge (no network call). */
    public function count(): int
    {
        if ($this->customer->check()) {
            return (int) session(self::COUNT, 0);
        }

        return array_sum(array_column($this->guestLines(), 'qty'));
    }

    /**
     * Everything the cart page needs.
     *
     * @return array{branch: ?array, guest: bool, lines: array, count: int, subtotal: float, voucher_discount: float,
     *               loyalty_discount: float, total: float, voucher_code: ?string, redeem_points: bool,
     *               points_balance: int, points_used: int, cart_id: ?string}
     */
    public function view(): array
    {
        $branch = $this->branches->current();
        $empty = ['branch' => $branch, 'guest' => ! $this->customer->check(), 'lines' => [], 'count' => 0, 'subtotal' => 0.0,
            'voucher_discount' => 0.0, 'loyalty_discount' => 0.0, 'total' => 0.0, 'voucher_code' => null,
            'redeem_points' => false, 'points_balance' => 0, 'points_used' => 0, 'cart_id' => null];

        if (! $this->customer->check()) {
            $lines = [];
            foreach ($this->guestLines() as $l) {
                if (($line = $this->line($l['product_id'], $l['variant_id'], $l['qty'], null, $branch['id'] ?? null)) !== null) {
                    $lines[] = $line;
                }
            }
            $subtotal = round(array_sum(array_column($lines, 'line_total')), 2);

            return array_merge($empty, ['lines' => $lines, 'count' => array_sum(array_column($lines, 'qty')), 'subtotal' => $subtotal, 'total' => $subtotal]);
        }
        if ($branch === null) {
            return $empty;
        }

        return $this->fromServer($this->serverState($branch['id']), $branch) ?? $empty;
    }

    /**
     * Add to the cart, capped by live stock at the branch. Returns how many were added.
     *
     * @throws ShopException with the reason nothing (or less) was added
     */
    public function add(string $productId, string $variantId, int $qty): int
    {
        $qty = max(1, min(self::MAX_QTY, $qty));
        $branch = $this->branches->current() ?? throw new ShopException('Choose your pickup branch first: allow location, and we\'ll pick the nearest one.', 'no_branch');
        $product = $this->catalog->product($productId, $branch['id']);
        $variant = $this->variant($product, $variantId);
        if ($product === null || $variant === null) {
            throw new ShopException('This item is no longer available.');
        }
        $live = $this->liveStock($branch['id'], [$variantId]);
        if (! array_key_exists($variantId, $live)) {
            throw new ShopException('This item isn\'t sold at '.$branch['name'].'. Try another branch.');
        }
        $inCart = $this->quantityOf($variantId, $branch['id']);
        $room = $live[$variantId] - $inCart;
        if ($live[$variantId] <= 0) {
            throw new ShopException('This item is out of stock at '.$branch['name'].'.');
        }
        if ($room <= 0) {
            throw new ShopException("You already have all {$live[$variantId]} available in your cart.");
        }
        $add = min($qty, $room);
        $this->setQuantity($productId, $variantId, $inCart + $add, $branch['id']);

        return $add;
    }

    /** Set one line's quantity (0 removes it). @throws ShopException */
    public function update(string $productId, string $variantId, int $qty): void
    {
        $branchId = $this->branches->currentId() ?? throw new ShopException('Choose your pickup branch first.', 'no_branch');
        $qty = max(0, min(self::MAX_QTY, $qty));
        if ($qty > $this->quantityOf($variantId, $branchId)) {
            $live = $this->liveStock($branchId, [$variantId]);
            if (($live[$variantId] ?? 0) < $qty) {
                throw new ShopException('Only '.($live[$variantId] ?? 0).' available at your branch.');
            }
        }
        $this->setQuantity($productId, $variantId, $qty, $branchId);
    }

    /** Apply a voucher (signed in only; counted and limited by the database first, like the app). */
    public function applyVoucher(string $code): void
    {
        $code = mb_strtoupper(trim($code));
        $branchId = $this->requireServerCart();
        $token = $this->customer->idToken();
        $this->rest->rpc('register_voucher_attempt', ['p_code' => $code], $token);
        $state = $this->serverState($branchId) ?? throw new ShopException('Your cart is empty.');
        $this->sync($branchId, $this->itemsOf($state), $code, (bool) ($state['redeem_points'] ?? false));
    }

    public function removeVoucher(): void
    {
        $branchId = $this->requireServerCart();
        $state = $this->serverState($branchId) ?? throw new ShopException('Your cart is empty.');
        $this->sync($branchId, $this->itemsOf($state), null, (bool) ($state['redeem_points'] ?? false));
    }

    public function redeemPoints(bool $on): void
    {
        $branchId = $this->requireServerCart();
        $state = $this->serverState($branchId) ?? throw new ShopException('Your cart is empty.');
        $this->sync($branchId, $this->itemsOf($state), $state['voucher_code'] ?? null, $on);
    }

    /**
     * After sign-in: add the guest cart to the account's cart at the current branch, capped by live
     * stock. Returns a note when something was lowered or left out, else null. The guest cart is
     * cleared only once the server accepted the merged cart.
     */
    public function mergeGuestCart(): ?string
    {
        $guest = $this->guestLines();
        if ($guest === [] || ! $this->customer->check()) {
            return null;
        }
        $branch = $this->branches->current();
        if ($branch === null) {
            return null; // kept for later, once a branch is known
        }
        $state = $this->serverState($branch['id']);
        $items = [];
        foreach ($state['items'] ?? [] as $i) {
            $items[$i['variant_id']] = ['product_id' => $i['product_id'], 'variant_id' => $i['variant_id'], 'quantity' => (int) $i['quantity']];
        }
        $live = $this->liveStock($branch['id'], array_column($guest, 'variant_id'));
        $lowered = false;
        foreach ($guest as $g) {
            $current = $items[$g['variant_id']]['quantity'] ?? 0;
            $room = ($live[$g['variant_id']] ?? 0) - $current;
            $add = max(0, min($g['qty'], $room));
            if ($add < $g['qty']) {
                $lowered = true;
            }
            if ($add > 0) {
                $items[$g['variant_id']] = ['product_id' => $g['product_id'], 'variant_id' => $g['variant_id'], 'quantity' => $current + $add];
            }
        }
        $this->sync($branch['id'], array_values($items), $state['voucher_code'] ?? null, (bool) ($state['redeem_points'] ?? false));
        session()->forget(self::GUEST);

        return $lowered ? 'Some items you added before signing in were lowered or left out because '.$branch['name'].' doesn\'t have enough.' : null;
    }

    /**
     * The branch changed: move a signed-in customer's cart along, lowered to what the new branch has
     * (the app's moveToBranch). Returns a note when the cart changed. Guests' lines simply follow.
     */
    public function moveTo(?string $fromBranchId, string $toBranchId): ?string
    {
        if ($fromBranchId === null || $fromBranchId === $toBranchId || ! $this->customer->check()) {
            return null;
        }
        $old = $this->serverState($fromBranchId);
        if ($old === null || ($old['items'] ?? []) === []) {
            return null;
        }
        $live = $this->liveStock($toBranchId, array_column($old['items'], 'variant_id'));
        $items = [];
        $changed = false;
        foreach ($old['items'] as $i) {
            $q = min((int) $i['quantity'], $live[$i['variant_id']] ?? 0);
            if ($q < (int) $i['quantity']) {
                $changed = true;
            }
            if ($q > 0) {
                $items[] = ['product_id' => $i['product_id'], 'variant_id' => $i['variant_id'], 'quantity' => $q];
            }
        }
        $droppedDiscounts = false;
        try {
            $this->sync($toBranchId, $items, $old['voucher_code'] ?? null, (bool) ($old['redeem_points'] ?? false));
        } catch (ShopException $e) {
            if ($e->reason !== 'refused') {
                throw $e;
            }
            $this->sync($toBranchId, $items, null, false);
            $droppedDiscounts = true;
        }
        try {
            $this->sync($fromBranchId, [], null, false);
        } catch (ShopException) {
            // The move worked; a leftover cart stays at the old branch.
        }
        $name = $this->catalog->branch($toBranchId)['name'] ?? 'your new branch';

        return match (true) {
            $changed && $droppedDiscounts => "Your cart moved to $name. Some items were lowered or removed, and your voucher or points no longer apply.",
            $changed => "Your cart moved to $name. Some items were lowered or removed to match what $name has.",
            $droppedDiscounts => "Your cart moved to $name. Your voucher or points no longer apply there.",
            default => null,
        };
    }

    /** After an order is placed: the server already emptied the cart. */
    public function placed(): void
    {
        session()->put(self::COUNT, 0);
    }

    // ------------------------------------------------------------------------------------------

    private function setQuantity(string $productId, string $variantId, int $qty, string $branchId): void
    {
        if (! $this->customer->check()) {
            $lines = $this->guestLines();
            if ($qty <= 0) {
                unset($lines[$variantId]);
            } else {
                $lines[$variantId] = ['product_id' => $productId, 'variant_id' => $variantId, 'qty' => $qty];
            }
            session()->put(self::GUEST, $lines);

            return;
        }
        $state = $this->serverState($branchId);
        $items = [];
        foreach ($state['items'] ?? [] as $i) {
            $items[$i['variant_id']] = ['product_id' => $i['product_id'], 'variant_id' => $i['variant_id'], 'quantity' => (int) $i['quantity']];
        }
        if ($qty <= 0) {
            unset($items[$variantId]);
        } else {
            $items[$variantId] = ['product_id' => $productId, 'variant_id' => $variantId, 'quantity' => $qty];
        }
        $this->sync($branchId, array_values($items), $state['voucher_code'] ?? null, (bool) ($state['redeem_points'] ?? false));
    }

    private function quantityOf(string $variantId, string $branchId): int
    {
        if (! $this->customer->check()) {
            return (int) ($this->guestLines()[$variantId]['qty'] ?? 0);
        }
        foreach ($this->serverState($branchId)['items'] ?? [] as $i) {
            if ($i['variant_id'] === $variantId) {
                return (int) $i['quantity'];
            }
        }

        return 0;
    }

    /** @return array<string, array{product_id: string, variant_id: string, qty: int}> keyed by variant id */
    public function guestLines(): array
    {
        $lines = session(self::GUEST, []);

        return is_array($lines) ? $lines : [];
    }

    private function serverState(string $branchId): ?array
    {
        $state = $this->rest->rpc('get_customer_cart', ['p_branch_id' => $branchId], $this->customer->idToken());
        $state = is_array($state) && isset($state['cart_id']) ? $state : null;
        session()->put(self::COUNT, array_sum(array_map(fn ($i) => (int) $i['quantity'], $state['items'] ?? [])));

        return $state;
    }

    private function sync(string $branchId, array $items, ?string $voucher, bool $redeem): array
    {
        $state = $this->rest->rpc('sync_customer_cart', [
            'p_branch_id' => $branchId,
            'p_items' => array_values($items),
            'p_voucher_code' => $voucher,
            'p_redeem_points' => $redeem,
        ], $this->customer->idToken());
        $state = is_array($state) ? $state : [];
        session()->put(self::COUNT, array_sum(array_map(fn ($i) => (int) $i['quantity'], $state['items'] ?? [])));

        return $state;
    }

    private function itemsOf(array $state): array
    {
        return array_map(fn ($i) => ['product_id' => $i['product_id'], 'variant_id' => $i['variant_id'], 'quantity' => (int) $i['quantity']], $state['items'] ?? []);
    }

    private function requireServerCart(): string
    {
        if (! $this->customer->check()) {
            throw new ShopException('Sign in to use vouchers and points.', 'session');
        }

        return $this->branches->currentId() ?? throw new ShopException('Choose your pickup branch first.', 'no_branch');
    }

    /** Live stock per variant at the branch (only rows the branch carries). @return array<string, int> */
    private function liveStock(string $branchId, array $variantIds): array
    {
        $ids = array_values(array_unique(array_filter($variantIds)));
        if ($ids === []) {
            return [];
        }
        $out = [];
        foreach ($this->rest->select('branch_inventory', [
            'select' => 'variant_id,quantity,is_carried', 'branch_id' => 'eq.'.$branchId, 'variant_id' => 'in.('.implode(',', $ids).')',
        ]) as $row) {
            if (($row['is_carried'] ?? true) === false) {
                continue;
            }
            $out[$row['variant_id']] = ($out[$row['variant_id']] ?? 0) + (int) $row['quantity'];
        }

        return $out;
    }

    private function fromServer(?array $state, array $branch): ?array
    {
        if ($state === null) {
            return null;
        }
        $lines = [];
        foreach ($state['items'] ?? [] as $i) {
            if (($line = $this->line($i['product_id'], $i['variant_id'], (int) $i['quantity'], (float) $i['current_price'], $branch['id'], $i['variant_label'] ?? null)) !== null) {
                $lines[] = $line;
            }
        }
        $p = $state['pricing'] ?? [];

        return [
            'branch' => $branch,
            'guest' => false,
            'lines' => $lines,
            'count' => array_sum(array_column($lines, 'qty')),
            'subtotal' => (float) ($p['subtotal'] ?? 0),
            'voucher_discount' => (float) ($p['voucher_discount'] ?? 0),
            'loyalty_discount' => (float) ($p['loyalty_discount'] ?? 0),
            // Store pickup: no delivery fee, ever (the app's displayTotal).
            'total' => max(0, round((float) ($p['total'] ?? 0) - (float) ($p['delivery_fee'] ?? 0), 2)),
            'voucher_code' => $state['voucher_code'] ?? null,
            'redeem_points' => (bool) ($state['redeem_points'] ?? false),
            'points_balance' => (int) ($p['loyalty_points_balance'] ?? 0),
            'points_used' => (int) ($p['loyalty_points_used'] ?? 0),
            'cart_id' => $state['cart_id'],
        ];
    }

    private function line(string $productId, string $variantId, int $qty, ?float $price, ?string $branchId, ?string $label = null): ?array
    {
        $product = $this->catalog->product($productId, $branchId);
        $variant = $this->variant($product, $variantId);
        if ($product === null && $price === null) {
            return null;
        }
        $unit = $price ?? (float) ($variant['price'] ?? 0);

        return [
            'product_id' => $productId,
            'variant_id' => $variantId,
            'name' => $product['name'] ?? 'Saved item',
            'variant_label' => $variant['label'] ?? $label ?? '',
            'image' => $product['images'][0] ?? null,
            'qty' => $qty,
            'unit_price' => $unit,
            'line_total' => round($unit * $qty, 2),
            'stock' => $variant['stock'] ?? null,
        ];
    }

    private function variant(?array $product, string $variantId): ?array
    {
        foreach ($product['variants'] ?? [] as $v) {
            if ($v['id'] === $variantId) {
                return $v;
            }
        }

        return null;
    }
}

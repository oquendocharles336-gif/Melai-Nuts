<?php

namespace App\Services\Shop;

use Illuminate\Support\Facades\Cache;

/**
 * The public catalog, read exactly like the app reads it (lib/data/repositories/products_repository.dart):
 * active products and categories, their variants, and stock from branch_inventory (rows a branch
 * does not carry are ignored). With a branch, stock is that branch's; without one it is the
 * all-branches total and cards say "Choose a branch to see stock" instead of "In stock".
 *
 * Product arrays:
 *   [id, name, category_id, price, original_price, description, badge, images[], tags[], is_featured,
 *    variants => [[id, label, price, badge, stock]], stock, stock_label, only_left]
 */
class ShopCatalog
{
    public const BRANCH_COLUMNS = 'id,name,address,is_active,contact_phone,operating_hours,supports_delivery,supports_pickup,delivery_fee,latitude,longitude,is_warehouse';

    public function __construct(private SupabaseRest $rest) {}

    /** @return array<int, array{id: string, name: string, product_count: int}> */
    public function categories(?string $branchId = null): array
    {
        $products = $this->products($branchId);
        $counts = [];
        foreach ($products as $p) {
            $counts[$p['category_id']] = ($counts[$p['category_id']] ?? 0) + 1;
        }

        return array_values(array_filter(array_map(fn ($c) => [
            'id' => (string) $c['id'],
            'name' => (string) ($c['label'] ?? ''),   // the column is `label` (ProductCategory.fromRow in the app)
            'product_count' => $counts[$c['id']] ?? 0,
        ], $this->categoryRows()), fn ($c) => $c['product_count'] > 0));
    }

    /** @return array<int, array<string, mixed>> */
    public function products(?string $branchId = null): array
    {
        return $this->remember('products:'.($branchId ?? 'all'), fn () => $this->load($branchId));
    }

    public function product(string $id, ?string $branchId = null): ?array
    {
        foreach ($this->products($branchId) as $p) {
            if ($p['id'] === $id) {
                return $p;
            }
        }

        return null;
    }

    /** Best sellers first (get_popular_products, real units sold), then the rest by name. */
    public function popular(?string $branchId = null, int $limit = 8): array
    {
        $rank = [];
        try {
            foreach ((array) $this->remember('popular', fn () => $this->rest->rpc('get_popular_products', ['p_limit' => 24])) as $i => $row) {
                $rank[(string) ($row['product_id'] ?? '')] = $i;
            }
        } catch (ShopException) {
            // No ranking: catalog order.
        }
        $products = $this->products($branchId);
        usort($products, fn ($a, $b) => [($rank[$a['id']] ?? PHP_INT_MAX), $a['name']] <=> [($rank[$b['id']] ?? PHP_INT_MAX), $b['name']]);

        return array_slice($products, 0, $limit);
    }

    public function featured(?string $branchId = null, int $limit = 8): array
    {
        return array_slice(array_values(array_filter($this->products($branchId), fn ($p) => $p['is_featured'])), 0, $limit);
    }

    /** Every word must match the name, tags, category or description (same as the app's storefront search). */
    public function search(string $query, ?string $categoryId, ?string $branchId): array
    {
        $words = array_values(array_filter(preg_split('/\s+/u', mb_strtolower(trim($query))) ?: []));
        $categories = [];
        foreach ($this->categoryRows() as $c) {
            $categories[$c['id']] = mb_strtolower((string) ($c['label'] ?? ''));
        }

        return array_values(array_filter($this->products($branchId), function ($p) use ($words, $categoryId, $categories) {
            if ($categoryId !== null && $p['category_id'] !== $categoryId) {
                return false;
            }
            if ($words === []) {
                return true;
            }
            $hay = mb_strtolower(implode(' ', [$p['name'], implode(' ', $p['tags']), $categories[$p['category_id']] ?? '', $p['description']]));
            foreach ($words as $w) {
                if (! str_contains($hay, $w)) {
                    return false;
                }
            }

            return true;
        }));
    }

    /** Active branches (warehouses never shown to customers). */
    public function branches(): array
    {
        $rows = $this->remember('branches', fn () => $this->rest->select('branches', [
            'select' => self::BRANCH_COLUMNS, 'is_active' => 'eq.true', 'order' => 'name',
        ]));

        return array_values(array_filter(array_map(fn ($b) => [
            'id' => (string) $b['id'],
            'name' => (string) $b['name'],
            'address' => (string) ($b['address'] ?? ''),
            'phone' => $b['contact_phone'] ?? null,
            'hours' => $b['operating_hours'] ?? null,
            'open_for_pickup' => ($b['supports_pickup'] ?? false) && ! ($b['is_warehouse'] ?? false),
            'latitude' => isset($b['latitude']) ? (float) $b['latitude'] : null,
            'longitude' => isset($b['longitude']) ? (float) $b['longitude'] : null,
        ], $rows), fn ($b) => $b['open_for_pickup']));
    }

    public function branch(?string $id): ?array
    {
        foreach ($this->branches() as $b) {
            if ($b['id'] === $id) {
                return $b;
            }
        }

        return null;
    }

    /** Forget cached reads (after an order changes stock). */
    public function forgetStock(?string $branchId): void
    {
        Cache::forget($this->key('products:'.($branchId ?? 'all')));
        Cache::forget($this->key('products:all'));
    }

    // ------------------------------------------------------------------------------------------

    private function categoryRows(): array
    {
        return $this->remember('categories', fn () => $this->rest->select('product_categories', [
            'select' => 'id,label,sort_order', 'is_active' => 'eq.true', 'order' => 'sort_order',
        ]));
    }

    private function load(?string $branchId): array
    {
        $rows = $this->rest->select('products', ['select' => '*', 'is_active' => 'eq.true', 'order' => 'name']);
        if ($rows === []) {
            return [];
        }
        $ids = '('.implode(',', array_map(fn ($r) => $r['id'], $rows)).')';
        $variants = $this->rest->select('product_variants', ['select' => '*', 'product_id' => 'in.'.$ids, 'order' => 'sort_order']);
        $stockQuery = ['select' => 'product_id,variant_id,quantity,is_carried', 'product_id' => 'in.'.$ids];
        if ($branchId !== null) {
            $stockQuery['branch_id'] = 'eq.'.$branchId;
        }
        $stockByVariant = [];
        $stockByProduct = [];
        foreach ($this->rest->select('branch_inventory', $stockQuery) as $row) {
            if (($row['is_carried'] ?? true) === false) {
                continue;
            }
            $q = (int) $row['quantity'];
            if (! empty($row['variant_id'])) {
                $stockByVariant[$row['variant_id']] = ($stockByVariant[$row['variant_id']] ?? 0) + $q;
            }
            $stockByProduct[$row['product_id']] = ($stockByProduct[$row['product_id']] ?? 0) + $q;
        }
        $badgeQty = null;
        if ($branchId !== null) {
            try {
                $settings = $this->rest->rpc('get_storefront_settings');
                $n = is_array($settings) ? (int) ($settings['low_stock_badge_qty'] ?? 0) : 0;
                $badgeQty = $n > 0 ? $n : null;
            } catch (ShopException) {
                $badgeQty = null;
            }
        }

        $byProduct = [];
        foreach ($variants as $v) {
            if (($v['is_active'] ?? true) === false) {
                continue;
            }
            $byProduct[$v['product_id']][] = [
                'id' => (string) $v['id'],
                'label' => (string) ($v['label'] ?? ''),
                'price' => (float) ($v['price'] ?? 0),
                'badge' => $v['badge'] ?? null,
                'stock' => $stockByVariant[$v['id']] ?? 0,
            ];
        }

        return array_map(function ($r) use ($byProduct, $stockByProduct, $badgeQty) {
            $stock = $stockByProduct[$r['id']] ?? 0;
            $onlyLeft = $badgeQty !== null && $stock > 0 && $stock <= $badgeQty ? $stock : null;

            return [
                'id' => (string) $r['id'],
                'name' => (string) $r['name'],
                'category_id' => (string) ($r['category_id'] ?? ''),
                'price' => (float) ($r['price'] ?? 0),
                'original_price' => isset($r['original_price']) ? (float) $r['original_price'] : null,
                'description' => (string) ($r['description'] ?? ''),
                'badge' => $r['badge'] ?? null,
                'images' => array_values(array_filter((array) ($r['images'] ?? []), 'is_string')),
                'tags' => array_values(array_filter((array) ($r['tags'] ?? []), 'is_string')),
                'is_featured' => (bool) ($r['is_featured'] ?? false),
                'variants' => $byProduct[$r['id']] ?? [],
                'stock' => $stock,
                'only_left' => $onlyLeft,
                'stock_label' => $stock <= 0 ? 'Out of stock' : ($onlyLeft !== null ? "Only $onlyLeft left" : 'In stock'),
            ];
        }, $rows);
    }

    private function remember(string $what, \Closure $load): mixed
    {
        $seconds = max(0, (int) config('melai.shop.catalog_cache_seconds', 60));

        return $seconds === 0 ? $load() : Cache::remember($this->key($what), $seconds, $load);
    }

    private function key(string $what): string
    {
        return 'shop:catalog:'.$what;
    }
}

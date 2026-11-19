<?php

namespace App\Http\Controllers\Shop;

use App\Services\Shop\ShopBranch;
use App\Services\Shop\ShopCart;
use App\Services\Shop\ShopCatalog;
use App\Services\Shop\ShopException;
use Illuminate\Http\Request;

/** The public shop: home, browse and search, product pages, and the automatic pickup branch. */
class StorefrontController extends ShopController
{
    public function __construct(private ShopCatalog $catalog, private ShopBranch $branches, private ShopCart $cart) {}

    public function home()
    {
        $branch = $this->branches->current();
        try {
            $branchId = $branch['id'] ?? null;

            return view('shop.home', [
                'branch' => $branch,
                'categories' => $this->catalog->categories($branchId),
                'featured' => $this->catalog->featured($branchId),
                'popular' => $this->catalog->popular($branchId, 8),
                'error' => null,
            ]);
        } catch (ShopException $e) {
            return view('shop.home', ['branch' => $branch, 'categories' => [], 'featured' => [], 'popular' => [], 'error' => $e->getMessage()]);
        }
    }

    public function search(Request $request)
    {
        $data = $request->validate([
            'q' => ['nullable', 'string', 'max:100'],
            'category' => ['nullable', 'string', 'max:64'],
            'sort' => ['nullable', 'in:popular,price_asc,price_desc,name'],
        ]);
        $branch = $this->branches->current();
        $q = trim((string) ($data['q'] ?? ''));
        $category = $data['category'] ?? null;
        $sort = $data['sort'] ?? 'popular';
        try {
            $branchId = $branch['id'] ?? null;
            $results = $this->catalog->search($q, $category, $branchId);
            $results = match ($sort) {
                'price_asc' => collect($results)->sortBy('price')->values()->all(),
                'price_desc' => collect($results)->sortByDesc('price')->values()->all(),
                'name' => collect($results)->sortBy('name')->values()->all(),
                default => $this->rankedByPopularity($results, $branchId),
            };
            $categories = $this->catalog->categories($branchId);
            $error = null;
        } catch (ShopException $e) {
            [$results, $categories, $error] = [[], [], $e->getMessage()];
        }
        $categoryName = collect($categories)->firstWhere('id', $category)['name'] ?? null;

        return view('shop.search', compact('branch', 'q', 'category', 'categoryName', 'sort', 'results', 'categories', 'error'));
    }

    public function product(string $product)
    {
        $branch = $this->branches->current();
        try {
            $item = $this->catalog->product($product, $branch['id'] ?? null);
            abort_if($item === null, 404);
            $related = collect($this->catalog->products($branch['id'] ?? null))
                ->filter(fn ($p) => $p['category_id'] === $item['category_id'] && $p['id'] !== $item['id'])
                ->take(4)->values()->all();
        } catch (ShopException $e) {
            return redirect()->route('shop.home')->with('shop_error', $e->getMessage());
        }
        $inCart = [];
        if (! app(\App\Services\Shop\CustomerSession::class)->check()) {
            foreach ($this->cart->guestLines() as $l) {
                $inCart[$l['variant_id']] = $l['qty'];
            }
        }

        // The signed-in customer's own review and whether they may write one (a completed order
        // with this product). The list itself is loaded by shop.js (shop.product.reviews).
        $myReview = null;
        if (app(\App\Services\Shop\CustomerSession::class)->check()) {
            try {
                $myReview = app(\App\Services\Shop\ShopReviews::class)->mine($item['id']);
            } catch (ShopException $e) {
                $myReview = ['error' => true, 'can_review' => false, 'review' => null];
            }
        }

        return view('shop.product', ['product' => $item, 'related' => $related, 'branch' => $branch, 'inCart' => $inCart, 'myReview' => $myReview]);
    }

    /**
     * The browser's location (asked by the page, only with the customer's permission) picks the
     * nearest open branch. A signed-in customer's cart moves with it.
     */
    /**
     * The pickup branch: the nearest one to the browser's location (latitude / longitude, used once
     * and never stored: only the branch and its distance are kept for this visit), or a branch the
     * customer picked by hand (branch_id) when location is blocked, unavailable or timed out.
     */
    public function locate(Request $request)
    {
        $data = $request->validate([
            'branch_id' => ['nullable', 'string', 'max:64', 'required_without:latitude'],
            'latitude' => ['nullable', 'required_without:branch_id', 'numeric', 'between:-90,90'],
            'longitude' => ['nullable', 'required_with:latitude', 'numeric', 'between:-180,180'],
        ]);
        try {
            [$oldId, $branch] = filled($data['branch_id'] ?? null)
                ? $this->branches->choose((string) $data['branch_id'])
                : $this->branches->chooseFromLocation((float) $data['latitude'], (float) $data['longitude']);
            $note = $branch !== null && $oldId !== null && $oldId !== $branch['id'] ? $this->cart->moveTo($oldId, $branch['id']) : null;
        } catch (ShopException $e) {
            return $this->failed($e, $request);
        }
        if ($branch === null) {
            $message = filled($data['branch_id'] ?? null) ? 'That branch is not open for pickup right now. Please choose another.' : 'No branch has a map location yet. Please choose your branch from the list.';

            return $request->expectsJson() ? response()->json(['message' => $message], 422) : back()->with('shop_error', $message);
        }
        if (! $request->expectsJson()) {
            return back()->with('shop_status', $note ?? 'Pickup branch: '.$branch['name'].'.');
        }

        return response()->json([
            'branch' => ['id' => $branch['id'], 'name' => $branch['name'], 'distance_km' => $branch['distance_km'] ?? null, 'reason' => $branch['reason'] ?? null],
            'changed' => $oldId !== $branch['id'],
            'note' => $note,
        ]);
    }

    private function rankedByPopularity(array $results, ?string $branchId): array
    {
        $order = array_flip(array_column($this->catalog->popular($branchId, 500), 'id'));
        usort($results, fn ($a, $b) => ($order[$a['id']] ?? PHP_INT_MAX) <=> ($order[$b['id']] ?? PHP_INT_MAX));

        return $results;
    }
}

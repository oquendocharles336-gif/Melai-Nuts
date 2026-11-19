<?php

namespace App\Http\Controllers\Shop;

use App\Http\Requests\Rules;
use App\Services\Shop\ShopException;
use App\Services\Shop\ShopReviews;
use Illuminate\Http\Request;

/**
 * Product reviews on the shop: the list (JSON, loaded by shop.js with loading / empty / error /
 * retry states) for everyone, and the signed-in customer's own review (post, edit, delete).
 * The database decides who may review (a completed order with the product, one per product).
 */
class ReviewController extends ShopController
{
    public function __construct(private ShopReviews $reviews) {}

    public function index(Request $request, string $product)
    {
        $offset = max(0, min(10000, (int) $request->query('offset', 0)));
        try {
            return response()->json($this->reviews->page($product, $offset));
        } catch (ShopException $e) {
            return response()->json(['message' => 'We couldn\'t load the reviews. Please try again.'], $e->sessionEnded() ? 401 : 503);
        }
    }

    public function store(Request $request, string $product)
    {
        $data = $request->validate([
            'rating' => ['required', 'integer', 'between:1,5'],
            'comment' => Rules::reviewComment(),
        ], [
            'rating.required' => 'Choose 1 to 5 stars.',
            'rating.between' => 'Choose 1 to 5 stars.',
            'comment.max' => 'Your review cannot exceed '.Rules::REVIEW_MAX.' characters.',
        ]);
        try {
            $this->reviews->save($product, (int) $data['rating'], (string) ($data['comment'] ?? ''));
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.product', $product).'#reviews');
        }

        return redirect()->to(route('shop.product', $product).'#reviews')->with('shop_status', 'Thanks! Your review is saved.');
    }

    public function destroy(Request $request, string $product)
    {
        try {
            $this->reviews->delete($product);
        } catch (ShopException $e) {
            return $this->failed($e, $request, route('shop.product', $product).'#reviews');
        }

        return redirect()->to(route('shop.product', $product).'#reviews')->with('shop_status', 'Your review was deleted.');
    }
}

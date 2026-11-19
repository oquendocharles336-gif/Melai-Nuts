<?php

namespace App\Services\Shop;

use Illuminate\Support\Carbon;

/**
 * Product ratings and reviews on the shop (migration 20261119020000), through the same public
 * API and row-level security as the Melai Nuts app (ProductReviewsRepository):
 *
 *   * anyone reads the visible reviews (get_product_reviews: first name + last initial);
 *   * a signed-in customer writes, edits and deletes their OWN review, and only for a product of
 *     one of their COMPLETED orders (the database picks the order and refuses anything else).
 *
 * There is no staff on the website: hiding / deleting other people's reviews is in the app only.
 */
class ShopReviews
{
    public const PAGE = 10;

    public function __construct(private SupabaseRest $rest, private CustomerSession $customer) {}

    /** @return array{reviews: array<int, array<string, mixed>>, has_more: bool} */
    public function page(string $productId, int $offset = 0): array
    {
        $token = $this->customer->check() ? $this->customer->idToken() : null;
        $rows = $this->rest->rpc('get_product_reviews', [
            'p_product_id' => $productId, 'p_limit' => self::PAGE, 'p_offset' => max(0, $offset),
        ], $token);
        $reviews = array_map(fn ($r) => self::shape($r), is_array($rows) ? array_values(array_filter($rows, 'is_array')) : []);

        return ['reviews' => $reviews, 'has_more' => count($reviews) >= self::PAGE];
    }

    /**
     * The signed-in customer's own review and whether they may write one.
     *
     * @return array{can_review: bool, review: ?array<string, mixed>}
     */
    public function mine(string $productId): array
    {
        $s = $this->rest->rpc('my_product_review_status', ['p_product_id' => $productId], $this->customer->idToken());
        $review = is_array($s) && is_array($s['review'] ?? null) ? self::shape($s['review']) : null;

        return ['can_review' => is_array($s) && ($s['can_review'] ?? false) === true, 'review' => $review];
    }

    /** Post or edit the customer's review (one per product). */
    public function save(string $productId, int $rating, string $comment): void
    {
        $token = $this->customer->idToken();
        $mine = $this->mine($productId);
        if ($mine['review'] !== null) {
            $rows = $this->rest->update('product_reviews', ['id' => 'eq.'.$mine['review']['id'], 'select' => 'id'],
                ['rating' => $rating, 'comment' => trim($comment)], $token);
            if ($rows === []) {
                throw new ShopException('We couldn\'t save your review. Please try again.', 'refused');
            }
        } elseif ($mine['can_review']) {
            $this->rest->insert('product_reviews', [
                'product_id' => $productId,
                'customer_id' => (string) $this->customer->uid(),
                'rating' => $rating,
                'comment' => trim($comment),
            ], $token);
        } else {
            throw new ShopException('You can review this product once an order with it is completed.', 'refused');
        }
        ShopCatalog::invalidate();   // the average on the cards
    }

    public function delete(string $productId): void
    {
        $mine = $this->mine($productId);
        if ($mine['review'] === null) {
            return;
        }
        $this->rest->delete('product_reviews', ['id' => 'eq.'.$mine['review']['id'], 'select' => 'id'], $this->customer->idToken());
        ShopCatalog::invalidate();
    }

    /** @return array<string, mixed> */
    private static function shape(array $r): array
    {
        $created = (string) ($r['created_at'] ?? '');
        $updated = (string) ($r['updated_at'] ?? $created);

        return [
            'id' => (string) ($r['id'] ?? ''),
            'rating' => max(1, min(5, (int) ($r['rating'] ?? 0))),
            'comment' => (string) ($r['comment'] ?? ''),
            'name' => trim((string) ($r['reviewer_name'] ?? '')) ?: 'Customer',
            'date' => $created !== '' ? Carbon::parse($created)->timezone(config('app.timezone'))->format('M j, Y') : '',
            'edited' => $created !== '' && $updated !== '' && abs(strtotime($updated) - strtotime($created)) > 1,
            'mine' => ($r['is_mine'] ?? false) === true,
            'hidden' => ($r['is_hidden'] ?? false) === true,
        ];
    }
}

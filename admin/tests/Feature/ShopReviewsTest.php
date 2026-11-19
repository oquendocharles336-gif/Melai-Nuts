<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use Tests\Support\FakeFirebase;
use Tests\Support\FakeShopSupabase;
use Tests\TestCase;

/** Product ratings and reviews on the shop (migration 20261119020000; the database rules are in supabase/tests/product_reviews_test.sql). */
class ShopReviewsTest extends TestCase
{
    use RefreshDatabase;

    private FakeFirebase $fb;

    private FakeShopSupabase $shop;

    protected function setUp(): void
    {
        parent::setUp();
        $this->fb = (new FakeFirebase)->install();
        $this->shop = (new FakeShopSupabase)->install();
    }

    private function signIn(string $uid = 'cust-1', string $email = 'ana@example.com'): void
    {
        $this->fb->addAccount($email, $uid, 'Kasoy#Roast9', verified: true);
        $this->fb->profiles[$uid] = ['email' => $email, 'name' => 'Ana Cruz', 'role' => 'customer', 'isActive' => true, 'phone' => '+639171234567'];
        $this->shop->profiles[$uid] = ['firebase_uid' => $uid, 'full_name' => 'Ana Cruz', 'phone' => '+639171234567'];
        $this->shop->legal[$uid] = ['terms_version' => config('melai.legal.terms_version'), 'privacy_version' => config('melai.legal.privacy_version')];
        $this->shop->reviewerNames[$uid] = 'Ana C.';
        $this->post('/login', ['email' => $email, 'password' => 'Kasoy#Roast9'])->assertRedirect();
    }

    private function review(string $id, string $product, string $uid, int $rating, string $comment = '', bool $hidden = false): void
    {
        $this->shop->reviews[$id] = ['id' => $id, 'product_id' => $product, 'customer_id' => $uid, 'rating' => $rating, 'comment' => $comment,
            'is_hidden' => $hidden, 'created_at' => '2026-11-0'.(count($this->shop->reviews) + 1).'T02:00:00Z',
            'updated_at' => '2026-11-0'.(count($this->shop->reviews) + 1).'T02:00:00Z', 'reviewer_name' => 'Ben S.'];
    }

    public function test_cards_and_the_product_page_show_the_real_average_and_count_only(): void
    {
        $this->review('r1', 'p-1', 'other-1', 5, 'Spicy and crunchy');
        $this->review('r2', 'p-1', 'other-2', 4);
        $this->review('r3', 'p-1', 'other-3', 1, 'spam', hidden: true);   // hidden: not counted

        $this->get('/')->assertOk()->assertSee('4.5 (2)')->assertSee('Rated 4.5 out of 5 from 2 reviews', false);
        $this->get('/shop/p/p-1')->assertOk()->assertSee('Ratings &amp; reviews', false)->assertSee('2 reviews')
            ->assertSee('data-reviews="'.route('shop.product.reviews', 'p-1').'"', false);
        // A product nobody reviewed: no made-up rating.
        $this->get('/shop/p/p-2')->assertOk()->assertDontSee('s-reviews-summary', false);
    }

    public function test_the_review_list_loads_as_json_with_first_name_and_last_initial(): void
    {
        $this->review('r1', 'p-1', 'other-1', 5, 'Spicy and crunchy');
        $this->getJson('/shop/p/p-1/reviews.json')->assertOk()
            ->assertJsonPath('reviews.0.name', 'Ben S.')->assertJsonPath('reviews.0.rating', 5)
            ->assertJsonPath('reviews.0.comment', 'Spicy and crunchy')->assertJsonPath('reviews.0.date', 'Nov 1, 2026')
            ->assertJsonPath('has_more', false)->assertJsonMissingPath('reviews.0.customer_id');
        $this->getJson('/shop/p/p-2/reviews.json')->assertOk()->assertJsonPath('reviews', []);
    }

    public function test_the_list_reports_an_error_the_page_can_retry(): void
    {
        config(['melai.shop.supabase_url' => '']);
        $this->getJson('/shop/p/p-1/reviews.json')->assertStatus(503)->assertJsonPath('message', 'We couldn\'t load the reviews. Please try again.');
    }

    public function test_only_a_customer_who_received_the_product_can_post_edit_and_delete_their_own_review(): void
    {
        // A guest is asked to sign in; posting needs a customer sign-in.
        $this->get('/shop/p/p-1')->assertOk()->assertSee('to review a product you received');
        $this->post('/shop/p/p-1/review', ['rating' => 5])->assertRedirect();
        $this->assertSame([], $this->shop->reviews);

        // Signed in, but no completed order with the product: no form, and the server refuses too.
        $this->signIn();
        $this->get('/shop/p/p-1')->assertOk()->assertSee('once an order with it is completed')->assertDontSee('data-review-form', false);
        $this->post('/shop/p/p-1/review', ['rating' => 5])->assertSessionHas('shop_error');
        $this->assertSame([], $this->shop->reviews);

        // Received it (a completed order): post.
        $this->shop->received['cust-1'] = ['p-1'];
        $this->get('/shop/p/p-1')->assertOk()->assertSee('data-review-form', false)->assertSee('Post review');
        $this->post('/shop/p/p-1/review', ['rating' => 0, 'comment' => '🔥🔥'])->assertSessionHasErrors(['rating', 'comment']);
        $this->post('/shop/p/p-1/review', ['rating' => 4, 'comment' => '  Fresh and crunchy  '])
            ->assertRedirect(route('shop.product', 'p-1').'#reviews')->assertSessionHas('shop_status');
        $mine = array_values($this->shop->reviews)[0];
        $this->assertSame(['cust-1', 4, 'Fresh and crunchy'], [$mine['customer_id'], $mine['rating'], $mine['comment']]);
        $this->assertSame('cust-1', $this->shop->asCustomer('/rest/v1/product_reviews')[0]['body']['customer_id']);

        // Edit (one review per product: the same row is updated).
        $this->get('/shop/p/p-1')->assertOk()->assertSee('Save changes')->assertSee('Delete my review');
        $this->post('/shop/p/p-1/review', ['rating' => 5, 'comment' => 'Best cashews'])->assertSessionHas('shop_status');
        $this->assertCount(1, $this->shop->reviews);
        $this->assertSame([5, 'Best cashews'], [array_values($this->shop->reviews)[0]['rating'], array_values($this->shop->reviews)[0]['comment']]);

        // Delete.
        $this->delete('/shop/p/p-1/review')->assertSessionHas('shop_status', 'Your review was deleted.');
        $this->assertSame([], $this->shop->reviews);
    }

    public function test_a_customer_cannot_change_someone_elses_review_and_there_is_no_staff_moderation_on_the_website(): void
    {
        $this->review('r1', 'p-1', 'other-1', 5, 'Good');
        $this->signIn();
        $this->shop->received['cust-1'] = ['p-1'];
        $this->delete('/shop/p/p-1/review');                // has no review of their own: nothing happens
        $this->assertArrayHasKey('r1', $this->shop->reviews);
        $this->assertFalse(Route::has('shop.product.review.hide'));
        $this->assertSame([], array_filter(array_keys(Route::getRoutes()->getRoutesByName()),
            fn ($n) => str_contains($n, 'review') && str_contains($n, 'moderat')));
    }
}

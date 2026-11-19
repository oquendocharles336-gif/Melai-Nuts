<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * The owner's "Product reviews" page (admin website). The database side (who may read every
 * review, filters, sort, moderation) is tested in supabase/tests/blocked_words_test.sql.
 */
class AdminProductReviewsTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private const R1 = '11111111-1111-4111-8111-111111111111';
    private const R2 = '22222222-2222-4222-8222-222222222222';
    private const P1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    private const P2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

    protected function setUp(): void
    {
        parent::setUp();
        $this->useFakeSupabase();
        $row = fn ($id, $p, $pn, $name, $rating, $comment, $at, $hidden = false) => ['id' => $id, 'product_id' => $p, 'product_name' => $pn,
            'order_id' => 'ORD-1', 'customer_name' => $name, 'customer_email' => strtolower(strtok($name, ' ')).'@example.com', 'rating' => $rating,
            'comment' => $comment, 'is_hidden' => $hidden, 'hidden_at' => null, 'created_at' => $at, 'updated_at' => $at];
        $this->db->reviews = [
            self::R1 => $row(self::R1, self::P1, 'Garlic Peanuts', 'Ana Dela Cruz', 5, 'Crunchy and fresh', '2026-11-10T02:00:00Z'),
            self::R2 => $row(self::R2, self::P2, 'Roasted Cashew', 'Ben Santos', 1, 'Spam spam spam', '2026-11-12T02:00:00Z'),
        ];
    }

    private ?\App\Models\User $ownerLogin = null;

    private function owner(): static
    {
        return $this->signedIn($this->ownerLogin ??= $this->linkedLogin('uid-owner'));
    }

    public function test_owner_pages_never_show_the_app_download_link(): void
    {
        config(['melai.shop.app_download_url' => 'https://www.mediafire.com/file/abc123/MelaiNuts-v1.0.0.apk/file']);
        $this->owner()->get('/admin/reviews')->assertOk()
            ->assertDontSee('mediafire.com')
            ->assertDontSee('Get the Melai Nuts app');
    }

    public function test_the_owner_sees_every_review_with_product_customer_rating_comment_and_date(): void
    {
        $this->owner()->get('/admin/reviews')->assertOk()
            ->assertSee('Product reviews')
            ->assertSeeInOrder(['Roasted Cashew', 'Ben Santos', 'Spam spam spam', 'Nov 12, 2026', 'Garlic Peanuts', 'Ana Dela Cruz', 'Crunchy and fresh', 'Nov 10, 2026']);
        $this->assertSame('admin_list_product_reviews', collect($this->db->calls)->last()['fn']);
        $this->assertSame('uid-owner', collect($this->db->calls)->last()['uid'], 'read as the signed-in owner, never another account');
    }

    public function test_filter_by_product_search_and_sort(): void
    {
        $this->owner()->get('/admin/reviews?product='.self::P1)->assertOk()->assertSee('Crunchy and fresh')->assertDontSee('Spam spam spam');
        $this->owner()->get('/admin/reviews?q=santos')->assertOk()->assertSee('Spam spam spam')->assertDontSee('Crunchy and fresh');
        $this->owner()->get('/admin/reviews?sort=oldest')->assertOk()->assertSeeInOrder(['Crunchy and fresh', 'Spam spam spam']);
        $this->owner()->get('/admin/reviews?q=nothing-like-this')->assertOk()->assertSee('No reviews match these filters.');
        // Bad filter values fall back to the defaults instead of reaching the database.
        $this->owner()->get('/admin/reviews?product=not-a-uuid&status=weird&sort=drop')->assertOk();
        $b = collect($this->db->calls)->last()['bindings'];
        $this->assertSame([null, null, 'all', 'newest'], array_slice($b, 0, 4));
    }

    public function test_hide_show_and_delete(): void
    {
        $this->owner()->post('/admin/reviews/'.self::R2.'/moderate', ['action' => 'hide', 'sort' => 'oldest'])
            ->assertRedirect(route('admin.reviews.index', ['sort' => 'oldest']))->assertSessionHas('status', 'Review hidden: customers no longer see it.');
        $this->assertTrue($this->db->reviews[self::R2]['is_hidden']);
        $this->owner()->get('/admin/reviews?status=hidden')->assertOk()->assertSee('Spam spam spam')->assertSee('Hidden')->assertDontSee('Crunchy and fresh');

        $this->owner()->post('/admin/reviews/'.self::R2.'/moderate', ['action' => 'show'])->assertSessionHas('status', 'Review visible again.');
        $this->assertFalse($this->db->reviews[self::R2]['is_hidden']);

        $this->owner()->post('/admin/reviews/'.self::R2.'/moderate', ['action' => 'delete'])->assertSessionHas('status', 'Review deleted.');
        $this->assertArrayNotHasKey(self::R2, $this->db->reviews);
        $this->assertDatabaseHas('activity_logs', ['action' => 'review.delete']);

        $this->owner()->post('/admin/reviews/'.self::R1.'/moderate', ['action' => 'publish'])->assertSessionHasErrors('action');
        $this->owner()->post('/admin/reviews/not-a-uuid/moderate', ['action' => 'hide'])->assertNotFound();
    }

    public function test_only_the_owner_can_open_or_change_it(): void
    {
        $this->get('/admin/reviews')->assertRedirect();
        $this->post('/admin/reviews/'.self::R1.'/moderate', ['action' => 'delete'])->assertRedirect();
        $staff = $this->linkedLogin('uid-cal');
        // Staff use the app only: the website signs them out before any admin page.
        $this->signedIn($staff)->get('/admin/reviews')->assertRedirect();
        $this->signedIn($staff)->post('/admin/reviews/'.self::R1.'/moderate', ['action' => 'delete'])->assertRedirect();
        $this->assertArrayHasKey(self::R1, $this->db->reviews);
    }

    public function test_the_sidebar_links_to_it_for_the_owner(): void
    {
        $this->owner()->get('/admin/reviews')->assertOk()->assertSee(route('admin.reviews.index'), false);
    }
}

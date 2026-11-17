<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Http;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Products page > Photos: upload / replace / reorder / remove, as the owner, through Supabase Storage
 * (faked here at the HTTP level) and the owner_*_product_image functions (FakeSupabase; the real SQL
 * is tested in supabase/tests/product_photos_test.sql).
 */
class ProductPhotosTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    private const PRODUCT = '6f1c2b9e-1a2b-4c3d-8e9f-0a1b2c3d4e5f';
    private const STORAGE = 'https://demo.supabase.co/storage/v1/object';

    /** Requests the website sent to Supabase Storage: [method, url, headers, body]. */
    private array $storage = [];
    private int $storageStatus = 200;

    protected function setUp(): void
    {
        parent::setUp();
        config(['melai.shop.supabase_url' => 'https://demo.supabase.co', 'melai.shop.anon_key' => 'anon-key']);
        $this->useFakeSupabase();
        $this->db->products[self::PRODUCT] = ['id' => self::PRODUCT, 'name' => 'Chili Garlic Peanuts', 'sku' => null, 'unit' => '250g pack',
            'price' => 110, 'is_active' => true, 'is_featured' => true, 'category' => 'Flavored Nuts', 'images' => [], 'updated_at' => now()->toIso8601String(),
            'variants' => [['id' => 'v1', 'label' => 'Regular', 'sku' => null, 'price' => 110, 'stock' => 167]]];
        Http::fake(['demo.supabase.co/storage/*' => function (HttpRequest $r) {
            $this->storage[] = [$r->method(), $r->url(), $r->headers(), $r->body()];

            return Http::response($this->storageStatus < 300 ? ['Key' => 'ok'] : ['message' => 'new row violates row-level security policy'], $this->storageStatus);
        }]);
    }

    private function photo(string $name = 'nuts.jpg', int $w = 640, int $h = 480): UploadedFile
    {
        return UploadedFile::fake()->image($name, $w, $h);
    }

    private function owner(): \App\Models\User
    {
        return $this->linkedLogin('uid-owner');
    }

    private function images(): array
    {
        return $this->db->products[self::PRODUCT]['images'];
    }

    public function test_the_products_page_shows_photos_and_the_add_photo_button_to_the_owner(): void
    {
        $this->db->products[self::PRODUCT]['images'] = ['https://demo.supabase.co/storage/v1/object/public/product-images/'.self::PRODUCT.'/a.webp'];

        $this->signedIn($this->owner())->get('/s/products')->assertOk()
            ->assertSee('Chili Garlic Peanuts')
            ->assertSee('Photos 1/3')
            ->assertSee('product-photos', false)
            ->assertSee('a.webp', false);   // in the page's photo list (JSON)
    }

    public function test_the_owner_uploads_a_photo_to_storage_and_the_product(): void
    {
        $r = $this->signedIn($this->owner())->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])
            ->assertOk()->assertJsonPath('message', 'Photo added. Customers see it in the app.');

        $this->assertCount(1, $this->images());
        $url = $this->images()[0];
        $this->assertMatchesRegularExpression('#^https://demo\.supabase\.co/storage/v1/object/public/product-images/'.self::PRODUCT.'/[a-z0-9]{26}\.jpg$#', $url);
        $this->assertSame([$url], $r->json('images'));

        // The file went to Storage AS the owner (their Firebase ID token), with the public key, as a JPEG.
        [$method, $sent, $headers, $body] = $this->storage[0];
        $this->assertSame('POST', $method);
        $this->assertSame(self::STORAGE.'/product-images/'.substr($url, strlen(self::STORAGE.'/public/product-images/')), $sent);
        $this->assertSame(['anon-key'], $headers['apikey']);
        $this->assertStringStartsWith('Bearer ey', $headers['Authorization'][0]);
        $this->assertSame(['image/jpeg'], $headers['Content-Type']);
        $this->assertNotSame('', $body);
        $this->assertNull($this->db->calls[array_key_last($this->db->calls)]['bindings'][2], 'a new photo, not a replacement');
    }

    public function test_at_most_three_photos_and_a_refused_photo_leaves_no_file_behind(): void
    {
        $owner = $this->owner();
        foreach (['a.jpg', 'b.png', 'c.webp'] as $name) {
            $file = str_ends_with($name, '.webp') ? UploadedFile::fake()->createWithContent($name, $this->webp()) : $this->photo($name);
            $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $file])->assertOk();
        }
        $this->assertCount(3, $this->images());
        $this->assertStringEndsWith('.png', $this->images()[1]);
        $this->assertStringEndsWith('.webp', $this->images()[2]);

        $this->storage = [];
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('d.jpg')])
            ->assertStatus(403)->assertJsonPath('message', 'A product can have at most 3 photos. Replace or remove one first.');
        $this->assertCount(3, $this->images());
        $this->assertSame(['POST', 'DELETE'], array_column($this->storage, 0), 'the uploaded file is deleted again');
        $this->assertStringStartsWith(self::PRODUCT.'/', json_decode($this->storage[1][3], true)['prefixes'][0]);
    }

    public function test_replacing_keeps_the_position_and_deletes_the_old_file(): void
    {
        $owner = $this->owner();
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('a.jpg')]);
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('b.jpg')]);
        [$first, $second] = $this->images();

        $this->storage = [];
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('new.jpg'), 'replace' => $first])
            ->assertOk()->assertJsonPath('message', 'Photo replaced. Customers see the new photo in the app.');

        $this->assertCount(2, $this->images());
        $this->assertNotSame($first, $this->images()[0], 'a replaced photo gets a new URL (no stale cache anywhere)');
        $this->assertSame($second, $this->images()[1]);
        $this->assertSame('DELETE', $this->storage[1][0]);
        $this->assertSame(['prefixes' => [self::PRODUCT.'/'.basename($first)]], json_decode($this->storage[1][3], true));
    }

    public function test_make_main_and_remove(): void
    {
        $owner = $this->owner();
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('a.jpg')]);
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo('b.jpg')]);
        [$a, $b] = $this->images();

        $this->signedIn($owner)->putJson(route('ops.products.photos.order', self::PRODUCT), ['images' => [$b, $a]])
            ->assertOk()->assertJsonPath('images', [$b, $a]);
        $this->assertSame([$b, $a], $this->images());

        $this->storage = [];
        $this->signedIn($owner)->deleteJson(route('ops.products.photos.destroy', self::PRODUCT), ['url' => $b])
            ->assertOk()->assertJsonPath('images', [$a]);
        $this->assertSame([$a], $this->images());
        $this->assertSame(['prefixes' => [self::PRODUCT.'/'.basename($b)]], json_decode($this->storage[0][3], true));

        $this->signedIn($owner)->deleteJson(route('ops.products.photos.destroy', self::PRODUCT), ['url' => $a])
            ->assertOk()->assertJsonPath('images', [])->assertJsonPath('message', "Photo removed. The app shows the product's placeholder until you add a photo.");
    }

    public function test_only_images_are_accepted(): void
    {
        $owner = $this->owner();
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => UploadedFile::fake()->create('menu.pdf', 20, 'application/pdf')])
            ->assertStatus(422)->assertJsonValidationErrors('photo');
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => UploadedFile::fake()->createWithContent('fake.jpg', 'not really a photo')])
            ->assertStatus(422)->assertJsonValidationErrors('photo');
        $this->signedIn($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => UploadedFile::fake()->image('huge.jpg')->size(6000)])
            ->assertStatus(422)->assertJsonValidationErrors('photo');
        $this->assertSame([], $this->storage, 'nothing reached Storage');
        $this->assertSame([], $this->images());
    }

    public function test_storage_refusing_the_owner_is_a_clear_message_and_nothing_is_saved(): void
    {
        $this->storageStatus = 403;
        $this->signedIn($this->owner())->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])
            ->assertStatus(403)->assertJsonPath('message', fn ($m) => str_contains($m, 'only an active owner can change product photos'));
        $this->assertSame([], $this->images());
    }

    public function test_a_website_password_session_is_told_to_sign_in_with_the_app_account(): void
    {
        // Signed in to the website without an app (Firebase) sign-in: Storage cannot be called as the owner.
        $this->actingAs($this->owner())->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])
            ->assertStatus(403)->assertJsonPath('message', fn ($m) => str_contains($m, 'needs your Melai Nuts app sign-in'));
        $this->assertSame([], $this->storage);
    }

    public function test_bad_product_ids_are_404(): void
    {
        $this->signedIn($this->owner())->postJson('/products/not-a-uuid/photos', ['photo' => $this->photo()])->assertNotFound();
    }

    public function test_a_shop_customer_or_guest_cannot_change_photos(): void
    {
        $this->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])->assertStatus(401);
        $this->deleteJson(route('ops.products.photos.destroy', self::PRODUCT), ['url' => 'x'])->assertStatus(401);
        $this->assertSame([], $this->storage);
    }

    public function test_the_web_shop_catalog_cache_is_dropped_when_photos_change(): void
    {
        $before = \Illuminate\Support\Facades\Cache::get('shop:catalog:version', 0);
        $this->signedIn($this->owner())->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])->assertOk();
        $this->assertGreaterThan($before, \Illuminate\Support\Facades\Cache::get('shop:catalog:version', 0));
    }

    /** A real 1x1 WEBP image. */
    private function webp(): string
    {
        $img = imagecreatetruecolor(4, 4);
        ob_start();
        imagewebp($img);

        return (string) ob_get_clean();
    }
}

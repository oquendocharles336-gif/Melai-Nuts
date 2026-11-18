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

    public function test_no_app_sign_in_in_this_session_asks_for_the_app_password_and_never_signs_out(): void
    {
        // Signed in to the website, but this session holds no app (Firebase) sign-in (it expired,
        // or the owner came in before it was kept): Storage cannot be called as the owner yet.
        $owner = $this->owner();
        $this->actingAs($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])
            ->assertStatus(409)->assertJsonPath('reauth', true)
            ->assertJsonPath('message', fn ($m) => str_contains($m, 'Confirm your Melai Nuts app password') && str_contains($m, 'You stay signed in'));
        $this->assertAuthenticatedAs($owner);
        $this->assertSame([], $this->storage);
    }

    public function test_the_app_password_renews_the_sign_in_in_place_and_the_upload_then_works(): void
    {
        $owner = $this->owner();
        $this->actingAs($owner)->postJson(route('ops.products.photos.session'), ['current_password' => 'wrong'])
            ->assertStatus(422)->assertJsonValidationErrors('current_password');
        $this->actingAs($owner)->postJson(route('ops.products.photos.session'), ['current_password' => 'uid-owner#Pass1'])
            ->assertOk()->assertJsonPath('message', fn ($m) => str_contains($m, 'App sign-in confirmed'));
        $this->assertAuthenticatedAs($owner);
        $this->actingAs($owner)->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])->assertOk();
        $this->assertCount(1, $this->images());
    }

    public function test_a_login_without_an_app_account_is_told_to_use_the_app_account(): void
    {
        $u = \App\Models\User::factory()->create(['role' => 'admin', 'has_access' => true]);
        $this->actingAs($u)->postJson(route('ops.products.photos.session'), ['current_password' => 'x'])->assertForbidden();
    }

    public function test_the_upload_card_and_the_allow_step_are_on_the_page(): void
    {
        $this->signedIn($this->owner())->get('/s/products')->assertOk()
            ->assertSee('Upload photo')
            ->assertSee('Drag a photo here or click to choose')
            ->assertSee('JPG, PNG or WEBP · up to 5 MB ·', false)
            ->assertSee('Allow Melai Nuts to access your photos?')
            ->assertSee('Allow and choose photos')
            ->assertSee('Not now')
            ->assertSee('Photo access:', false)
            ->assertSee(route('legal.privacy').'#privacy-9', false)
            ->assertSee('aria-label="Add a photo to Chili Garlic Peanuts"', false)   // the empty holder opens the modal
            ->assertSee('blocker: null', false)                                       // nothing to fix for this owner
            ->assertSee('Are you sure you want to save')   // asked before anything is uploaded
            ->assertSee('Check that each photo shows this product.')
            ->assertSee('x-on:click="askSave()"', false);
    }

    public function test_the_page_asks_up_front_for_the_app_password_when_the_session_has_no_app_sign_in(): void
    {
        // Website session without the app (Firebase) sign-in: asked in place, before choosing a photo.
        $this->actingAs($this->owner())->get('/s/products')->assertOk()
            ->assertSee('reauth: true', false)
            ->assertSee('Confirm your Melai Nuts app password to upload or change photos. You stay signed in', false)
            ->assertSee('photos\\/app-session', false);
    }

    public function test_the_page_says_up_front_when_the_supabase_keys_are_missing(): void
    {
        config(['melai.shop.supabase_url' => '', 'melai.shop.anon_key' => '']);
        $this->signedIn($this->owner())->get('/s/products')->assertOk()
            ->assertSee('add SUPABASE_URL and SUPABASE_ANON_KEY', false);
    }

    public function test_the_upload_limit_follows_php_ini_and_never_passes_5_mb(): void
    {
        $limit = \App\Services\Supabase\ProductPhotoStorage::uploadLimitBytes();
        $this->assertGreaterThan(0, $limit);
        $this->assertLessThanOrEqual(5 * 1024 * 1024, $limit);
        $this->signedIn($this->owner())->get('/s/products')->assertSee('maxBytes: '.$limit, false);
    }

    public function test_a_staff_account_cannot_upload(): void
    {
        // Staff use the app only: the website refuses the session before any upload code runs.
        $staff = $this->linkedLogin('uid-cal');
        $this->assertStaffKeptOut($this->signedIn($staff)->post(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()]));
        $this->assertSame([], $this->storage);
        $this->assertSame([], $this->images());
    }

    public function test_the_privacy_policy_has_the_product_photos_section_in_both_languages(): void
    {
        $this->get('/privacy')->assertOk()
            ->assertSee('id="privacy-9"', false)
            ->assertSee('9. Product photos and file access')
            ->assertSee('reads only the photo files the owner picks')
            ->assertSee('public &quot;product-images&quot; folder', false)
            ->assertSee('Version '.config('melai.legal.privacy_version'), false);
        $this->get('/privacy?lang=fil')->assertOk()->assertSee('9. Mga larawan ng produkto at access sa mga file');
        $this->assertSame('2026-11-18', config('melai.legal.privacy_version'));
    }

    public function test_the_privacy_policy_describes_phone_verification_and_sign_in_protection(): void
    {
        $this->get('/privacy')->assertOk()
            ->assertSee('id="privacy-10"', false)->assertSee('10. Your mobile number and the first-order rule')
            ->assertSee('id="privacy-11"', false)->assertSee('Cloudflare Turnstile')->assertSee('Resend')
            ->assertSee('TO BE FILLED IN BY THE OWNER');
        $this->get('/terms')->assertOk()->assertSee('50% or 100%')->assertSee('confirm your payment by hand');
        $this->get('/privacy?lang=fil')->assertOk()->assertSee('10. Ang iyong mobile number at ang tuntunin sa unang order');
    }

    public function test_a_token_without_the_role_claim_gets_it_from_grant_role_claim_before_uploading(): void
    {
        // A real Firebase token has no `role` claim until grant-role-claim adds it; Storage would
        // then treat the upload as a guest and refuse it (row-level security).
        $calls = [];
        Http::fake(['demo.supabase.co/functions/v1/grant-role-claim' => function (HttpRequest $r) use (&$calls) {
            $calls[] = $r->header('Authorization')[0] ?? '';

            return Http::response(['granted' => true]);
        }]);
        $owner = $this->owner();
        $noRole = $this->fb->token($owner->firebase_uid, $owner->email, true, ['role' => null]);

        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, 3600, $noRole))
            ->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])->assertOk();

        $this->assertSame(['Bearer '.$noRole], $calls);                 // asked once, with the owner's own token
        $sent = $this->storage[0][2]['Authorization'][0];
        $this->assertNotSame('Bearer '.$noRole, $sent);                  // uploaded with the refreshed token
        $payload = json_decode(base64_decode(strtr(explode('.', substr($sent, 7))[1], '-_', '+/')), true);
        $this->assertSame('authenticated', $payload['role']);
        $this->assertCount(1, $this->images());
    }

    public function test_grant_role_claim_failing_is_a_clear_message_and_nothing_is_uploaded(): void
    {
        Http::fake(['demo.supabase.co/functions/v1/grant-role-claim' => Http::response(['error' => 'no service account'], 502)]);
        $owner = $this->owner();
        $noRole = $this->fb->token($owner->firebase_uid, $owner->email, true, ['role' => null]);

        $this->actingAs($owner)->withSession($this->fb->sessionFor($owner, 3600, $noRole))
            ->postJson(route('ops.products.photos.store', self::PRODUCT), ['photo' => $this->photo()])
            ->assertStatus(403)->assertJsonPath('message', fn ($m) => str_contains($m, 'grant-role-claim answered HTTP 502'));
        $this->assertSame([], $this->storage);
        $this->assertSame([], $this->images());
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

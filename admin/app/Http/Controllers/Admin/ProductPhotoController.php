<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Services\ActivityLogger;
use App\Services\Shop\ShopCatalog;
use App\Exceptions\BackendUnavailableException;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseSession;
use App\Services\Firebase\FirebaseTokenVerifier;
use App\Services\Supabase\ProductPhotoStorage;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;

/**
 * Products page > Photos: the owner adds, replaces, reorders and removes up to 3 photos per product.
 *
 * Files go to Supabase Storage as the owner (ProductPhotoStorage); the list of photos is
 * products.images, changed only through the owner_* SQL functions, which lock the product row, keep
 * at most 3 photos and refuse anyone but an active owner. The app and the web shop read the same
 * column, so every customer and every branch sees the same photos right away.
 *
 * All answers are JSON: {message, images: [urls, main photo first]}.
 */
class ProductPhotoController extends Controller
{
    /** Upload one photo: a new one, or (with `replace` = its current URL) in place of an existing one. */
    public function store(Request $request, string $product, ProductPhotoStorage $storage): JsonResponse
    {
        $product = $this->guard($product);
        $v = $request->validate([
            'photo' => ['required', 'file', 'mimes:jpg,jpeg,png,webp', 'mimetypes:image/jpeg,image/png,image/webp', 'max:5120'],
            'replace' => ['nullable', 'string', 'max:500'],
        ], [
            'photo.required' => 'Choose a photo to upload.',
            'photo.uploaded' => 'The photo could not be uploaded. It may be larger than this server accepts; try a smaller photo.',
            'photo.mimes' => 'Only JPG, JPEG, PNG and WEBP photos can be uploaded.',
            'photo.mimetypes' => 'Only JPG, JPEG, PNG and WEBP photos can be uploaded.',
            'photo.max' => 'That photo is larger than 5 MB. Choose a smaller photo.',
        ]);

        // The content must really be one of the allowed image types (not just the file name).
        $file = $request->file('photo');
        $info = @getimagesize($file->getRealPath());
        $mime = is_array($info) ? ($info['mime'] ?? '') : '';
        if (! isset(ProductPhotoStorage::TYPES[$mime]) || ($info[0] ?? 0) < 1 || ($info[1] ?? 0) < 1) {
            throw ValidationException::withMessages(['photo' => 'That file is not a readable JPG, PNG or WEBP photo.']);
        }
        if ($info[0] > 12000 || $info[1] > 12000) {
            throw ValidationException::withMessages(['photo' => 'That photo is too large (more than 12000 pixels wide or tall).']);
        }

        $url = $storage->upload($product, (string) file_get_contents($file->getRealPath()), $mime);
        try {
            $r = $this->repo()->addProductImage($product, $url, $v['replace'] ?? null);
        } catch (\Throwable $e) {
            // Not saved on the product: do not leave the file behind.
            $storage->delete([$storage->pathOf($product, $url)]);
            throw $e;
        }
        $this->deleteFiles($storage, $product, $r['removed']);

        $replaced = filled($v['replace'] ?? null);
        ActivityLogger::log($replaced ? 'product.photo_replaced' : 'product.photo_added',
            ($replaced ? 'Replaced a photo of' : 'Added a photo to')." product {$product}", null,
            ['product_id' => $product, 'url' => $url, 'replaced' => $v['replace'] ?? null, 'count' => count($r['images']), 'source' => 'supabase']);

        return $this->answer($replaced ? 'Photo replaced. Customers see the new photo in the app.' : 'Photo added. Customers see it in the app.', $r['images']);
    }

    public function destroy(Request $request, string $product, ProductPhotoStorage $storage): JsonResponse
    {
        $product = $this->guard($product);
        $v = $request->validate(['url' => ['required', 'string', 'max:500']]);

        $r = $this->repo()->removeProductImage($product, $v['url']);
        $this->deleteFiles($storage, $product, $r['removed']);
        ActivityLogger::log('product.photo_removed', "Removed a photo of product {$product}", null,
            ['product_id' => $product, 'url' => $v['url'], 'count' => count($r['images']), 'source' => 'supabase']);

        return $this->answer($r['images'] === [] ? 'Photo removed. The app shows the product\'s placeholder until you add a photo.' : 'Photo removed.', $r['images']);
    }

    /** New order of the same photos; the first one is the main photo in the catalog. */
    public function order(Request $request, string $product): JsonResponse
    {
        $product = $this->guard($product);
        $v = $request->validate([
            'images' => ['required', 'array', 'min:1', 'max:'.ProductPhotoStorage::MAX_PHOTOS],
            'images.*' => ['required', 'string', 'max:500', 'distinct'],
        ]);

        $r = $this->repo()->setProductImageOrder($product, array_values($v['images']));
        ActivityLogger::log('product.photos_reordered', "Changed the main photo of product {$product}", null,
            ['product_id' => $product, 'main' => $r['images'][0] ?? null, 'source' => 'supabase']);

        return $this->answer('Main photo updated.', $r['images']);
    }

    /**
     * The owner's app sign-in for photo uploads, renewed in place: the app password is checked by
     * Firebase for THIS login's app account (same UID) and the new tokens go into this browser
     * session. The owner is never signed out of the website for it. The password is not stored.
     */
    public function renewAppSession(Request $request, FirebaseAuthClient $client, FirebaseTokenVerifier $verifier, FirebaseSession $session): JsonResponse
    {
        $v = $request->validate(['current_password' => ['required', 'string', 'max:128']],
            ['current_password.required' => 'Enter your Melai Nuts app password.']);
        $user = $request->user();
        abort_unless($user && $user->usesFirebase(), 403, 'This login has no Melai Nuts app account.');
        $key = 'photo-app-session:'.$user->getAuthIdentifier();
        if (RateLimiter::tooManyAttempts($key, 5)) {
            throw ValidationException::withMessages(['current_password' => 'Too many wrong passwords. Try again in '.RateLimiter::availableIn($key).' seconds.']);
        }
        try {
            $tokens = $client->signIn((string) $user->email, $v['current_password']);
            $claims = $verifier->verify($tokens['id_token']);
        } catch (FirebaseAuthException $e) {
            if ($e->isTemporary() || $e->reason === FirebaseAuthException::NETWORK || $e->reason === FirebaseAuthException::CONFIG) {
                throw new BackendUnavailableException($e->getMessage());
            }
            RateLimiter::hit($key, 300);
            ActivityLogger::log('auth.password_confirm_failed', 'Wrong app password when renewing the photo sign-in', $user);
            throw ValidationException::withMessages(['current_password' => $e->isCredentialError() ? 'That password is not correct.' : $e->getMessage()]);
        }
        if (! hash_equals((string) $user->firebase_uid, (string) ($claims['sub'] ?? ''))) {
            throw ValidationException::withMessages(['current_password' => 'That sign-in belongs to another app account.']);
        }
        RateLimiter::clear($key);
        $session->store($tokens, $claims);
        ActivityLogger::log('auth.app_session_renewed', 'Renewed the app sign-in for product photos', $user);

        return response()->json(['message' => 'App sign-in confirmed. You can save your photos now.']);
    }

    // ------------------------------------------------------------------------------------------

    /** The product id from the URL (lower case, as Postgres writes it), or 404. */
    private function guard(string $product): string
    {
        abort_unless(preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $product), 404);
        abort_unless($this->platform()->isSupabase(), 503, 'Product photos need the Melai Nuts app database.');

        return strtolower($product);
    }

    private function deleteFiles(ProductPhotoStorage $storage, string $product, array $urls): void
    {
        $storage->delete(array_map(fn ($u) => $storage->pathOf($product, (string) $u), $urls));
    }

    private function answer(string $message, array $images): JsonResponse
    {
        ShopCatalog::invalidate();   // the web shop shows the new photos at once too

        return response()->json(['message' => $message, 'images' => array_values($images)]);
    }
}

<?php

namespace App\Services\Supabase;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Services\Firebase\FirebaseSession;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\PendingRequest;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;

/**
 * Product photo FILES in Supabase Storage (bucket `product-images`, public), for the owner's Products
 * page. The list of photos per product lives in products.images and is changed only through the
 * owner_* SQL functions (SupabaseRepository); this class only moves the files.
 *
 * Every request is made AS the signed-in owner: the Storage API is called with the owner's own
 * Firebase ID token (the same token the Melai Nuts app sends), so the bucket's policies decide
 * (supabase/migrations/20261117000000_product_photo_management.sql: active owner, product folder).
 * No service_role key is used or needed.
 *
 * Files: product-images/<product id>/<random>.<ext>. A new upload always gets a new name, so a
 * replaced photo has a new URL and no app or browser keeps showing the old one from its cache.
 */
class ProductPhotoStorage
{
    public const BUCKET = 'product-images';

    public const MAX_PHOTOS = 3;

    /** mime => file extension (the bucket allows exactly these). */
    public const TYPES = ['image/jpeg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp'];

    public function __construct(private FirebaseSession $firebase, private StaffIdentity $identity) {}

    public function configured(): bool
    {
        return filled($this->baseUrl()) && filled($this->anonKey());
    }

    /** Public URL of a file in the bucket. */
    public function publicUrl(string $path): string
    {
        return $this->baseUrl().'/storage/v1/object/public/'.self::BUCKET.'/'.$path;
    }

    /**
     * The file path of $url when it is a photo in THIS project's bucket and this product's folder;
     * null for anything else (an older external link), which is then never deleted from Storage.
     */
    public function pathOf(string $productId, string $url): ?string
    {
        $prefix = $this->publicUrl($productId.'/');

        if (! str_starts_with($url, $prefix)) {
            return null;
        }
        $name = substr($url, strlen($prefix));

        return preg_match('/^[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$/', $name) ? $productId.'/'.$name : null;
    }

    /** Upload one photo; returns its public URL. */
    public function upload(string $productId, string $bytes, string $mime): string
    {
        $ext = self::TYPES[$mime] ?? throw new BackendActionException('Only JPG, PNG and WEBP photos can be uploaded.');
        $path = $productId.'/'.Str::lower((string) Str::ulid()).'.'.$ext;

        $r = $this->send(fn () => $this->client()
            ->withHeaders(['Content-Type' => $mime, 'Cache-Control' => 'max-age=31536000', 'x-upsert' => 'false'])
            ->withBody($bytes, $mime)
            ->post($this->baseUrl().'/storage/v1/object/'.self::BUCKET.'/'.$path));

        if (! $r->successful()) {
            throw $this->refused($r, 'upload');
        }

        return $this->publicUrl($path);
    }

    /**
     * Delete files (paths inside the bucket). Best effort: a file that cannot be deleted only
     * wastes storage, it is no longer shown anywhere, so this logs instead of failing the action.
     */
    public function delete(array $paths): void
    {
        $paths = array_values(array_filter($paths));
        if ($paths === []) {
            return;
        }
        try {
            $r = $this->send(fn () => $this->client()->asJson()
                ->delete($this->baseUrl().'/storage/v1/object/'.self::BUCKET, ['prefixes' => $paths]));
            if (! $r->successful()) {
                Log::warning('[product-photos] could not delete old files', ['paths' => $paths, 'status' => $r->status(), 'body' => Str::limit($r->body(), 300)]);
            }
        } catch (\Throwable $e) {
            Log::warning('[product-photos] could not delete old files', ['paths' => $paths, 'error' => $e->getMessage()]);
        }
    }

    // ------------------------------------------------------------------------------------------

    private function baseUrl(): string
    {
        return rtrim((string) config('melai.shop.supabase_url'), '/');
    }

    private function anonKey(): string
    {
        return (string) config('melai.shop.anon_key');
    }

    private function client(): PendingRequest
    {
        if (! $this->configured()) {
            throw new BackendActionException('Photo uploads are not set up yet: add SUPABASE_URL and SUPABASE_ANON_KEY (the same values as the app) to the website\'s .env file.');
        }

        return Http::acceptJson()->timeout(60)->withHeaders([
            'apikey' => $this->anonKey(),
            'Authorization' => 'Bearer '.$this->idToken(),
        ]);
    }

    /** The owner's current Firebase ID token (refreshed when close to expiry). */
    private function idToken(): string
    {
        $user = Auth::user();
        $uid = $this->identity->uid($user);   // the linked app account; throws when the link is gone
        if (! $user || ! $user->usesFirebase() || ! $this->firebase->isFor($user) || $user->firebase_uid !== $uid) {
            // Signed in with the website's own password: there is no app sign-in to act with, and
            // Storage only accepts the app account's own token. Say so instead of signing out.
            throw new BackendActionException('Uploading photos needs your Melai Nuts app sign-in. Sign out, then sign in again with the email and password you use in the app.');
        }
        try {
            return $this->firebase->idTokenFor($user);
        } catch (FirebaseSessionRequiredException $e) {
            throw new BackendActionException('Your app sign-in has ended. Sign out and sign in again, then upload the photo again.', 0, $e);
        }
    }

    private function send(\Closure $request): \Illuminate\Http\Client\Response
    {
        try {
            return $request();
        } catch (ConnectionException $e) {
            Log::error('[product-photos] storage unreachable: '.$e->getMessage());
            throw new BackendUnavailableException('The photo storage could not be reached. Check the connection and try again.', 0, $e);
        }
    }

    private function refused(\Illuminate\Http\Client\Response $r, string $what): \RuntimeException
    {
        $body = $r->json();
        $message = is_array($body) ? (string) ($body['message'] ?? $body['error'] ?? '') : '';
        Log::warning("[product-photos] storage refused the $what", ['status' => $r->status(), 'message' => $message]);

        if (in_array($r->status(), [401, 403], true) || str_contains(strtolower($message), 'row-level security') || str_contains(strtolower($message), 'unauthorized')) {
            return new BackendActionException('Supabase refused the photo: only an active owner can change product photos. If you are the owner, run supabase/migrations/20261117000000_product_photo_management.sql and sign in again.');
        }
        if ($r->status() === 413 || str_contains(strtolower($message), 'size')) {
            return new BackendActionException('That photo is too large for the photo storage (5 MB at most).');
        }
        if (str_contains(strtolower($message), 'mime')) {
            return new BackendActionException('Only JPG, PNG and WEBP photos can be uploaded.');
        }
        if ($r->status() === 404 && str_contains(strtolower($message), 'bucket')) {
            return new BackendActionException('The product-images storage bucket is missing. Run supabase/migrations/20261117000000_product_photo_management.sql in the Supabase SQL editor.');
        }

        return new BackendUnavailableException('The photo storage returned an error (HTTP '.$r->status().'). Please try again.');
    }
}

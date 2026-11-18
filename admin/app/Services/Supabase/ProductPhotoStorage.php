<?php

namespace App\Services\Supabase;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Models\User;
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

    /**
     * Why $user cannot upload photos right now, as a message with the fix, or null when nothing is in
     * the way. Checked without any network call, so the Products page can say it BEFORE the owner
     * picks a photo (the same checks run again on upload, in client() / idToken()).
     */
    public function blocker(?User $user): ?string
    {
        if (! $this->configured()) {
            return 'Photo uploads are not set up yet: add SUPABASE_URL and SUPABASE_ANON_KEY (the same values as the app\'s env/supabase.json) to the website\'s .env file, then restart the website.';
        }
        if (! $user || ! $user->usesFirebase()) {
            return 'Uploading photos needs your Melai Nuts app account: sign in to this website with the email and password you use in the app.';
        }

        // An app account whose app sign-in is missing or ended is NOT blocked: the page asks for the
        // app password in place (needsAppSignIn) and carries on, without signing out.
        return null;
    }

    /** $user is an app account, but this browser session holds no app sign-in for it right now. */
    public function needsAppSignIn(?User $user): bool
    {
        return $user !== null && $user->usesFirebase() && ! $this->firebase->isFor($user);
    }

    /**
     * Largest photo this server accepts, in bytes: 5 MB, or less when php.ini's upload_max_filesize /
     * post_max_size are lower (PHP's own default is 2 MB). The page shrinks photos to fit under it
     * before uploading, so a low php.ini limit no longer makes uploads fail.
     */
    public static function uploadLimitBytes(): int
    {
        $limits = [5 * 1024 * 1024, self::iniBytes((string) ini_get('upload_max_filesize'))];
        $post = self::iniBytes((string) ini_get('post_max_size'));
        if ($post > 0) {
            $limits[] = max(256 * 1024, $post - 64 * 1024);   // room for the rest of the form
        }

        return min(array_filter($limits, fn (int $v) => $v > 0));
    }

    /** "2M" / "512K" / "1G" / "1048576" in bytes; 0 = no limit. */
    private static function iniBytes(string $value): int
    {
        $value = trim($value);
        if ($value === '' || ! preg_match('/^(\d+)\s*([kmg]?)/i', $value, $m)) {
            return 0;
        }

        return (int) $m[1] * match (strtolower($m[2])) { 'g' => 1024 ** 3, 'm' => 1024 ** 2, 'k' => 1024, default => 1 };
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
        if (! $user || ! $user->usesFirebase() || $user->firebase_uid !== $uid) {
            // Signed in with the website's own password: there is no app account to act with, and
            // Storage only accepts the app account's own token.
            throw new BackendActionException('Uploading photos needs your Melai Nuts app account: sign in to this website with the email and password you use in the app.');
        }
        if (! $this->firebase->isFor($user)) {
            // App account without a current app sign-in: the page asks for the app password in
            // place (409 reauth, bootstrap/app.php), the owner stays signed in.
            throw new FirebaseSessionRequiredException(\App\Services\Auth\LinkState::NOT_AUTHENTICATED, 'Confirm your Melai Nuts app password to keep changing photos.');
        }
        try {
            // Supabase only applies the owner rules to a token whose `role` claim is "authenticated";
            // Firebase tokens have no such claim until the grant-role-claim function adds it (the app
            // does the same in lib/core/services/supabase_token.dart). Without it Storage treats the
            // upload as a guest and refuses it ("new row violates row-level security policy").
            if (($this->firebase->claimsFor($user)['claims']['role'] ?? null) !== 'authenticated') {
                $this->grantRoleClaim($this->firebase->idTokenFor($user));
                if (($this->firebase->claimsFor($user, true)['claims']['role'] ?? null) !== 'authenticated') {
                    throw new BackendActionException('Your app account could not get the upload permission yet. Try again in a moment. If it keeps happening, check the grant-role-claim function and its FIREBASE_SERVICE_ACCOUNT secret in Supabase (supabase/functions/README.md).');
                }
            }

            return $this->firebase->idTokenFor($user);
        } catch (FirebaseSessionRequiredException $e) {
            // Ended (expired refresh token, password changed elsewhere): renewed in place, see above.
            throw $e;
        }
    }

    /** Asks the grant-role-claim edge function to add role=authenticated to this Firebase account. */
    private function grantRoleClaim(string $idToken): void
    {
        $r = $this->send(fn () => Http::acceptJson()->timeout(20)
            ->withHeaders(['apikey' => $this->anonKey(), 'Authorization' => 'Bearer '.$idToken])
            ->post($this->baseUrl().'/functions/v1/grant-role-claim'));

        if (! $r->successful()) {
            Log::warning('[product-photos] grant-role-claim refused', ['status' => $r->status(), 'body' => Str::limit($r->body(), 300)]);
            throw new BackendActionException('Supabase could not give your app account the upload permission (grant-role-claim answered HTTP '.$r->status().'). Check that function and its FIREBASE_SERVICE_ACCOUNT secret (supabase/functions/README.md).');
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
            return new BackendActionException('Supabase refused the photo: only an active owner can change product photos. If you are the owner, check that the migrations up to 20261118040000_verified_phone_first_order.sql are applied (supabase migration list).');
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

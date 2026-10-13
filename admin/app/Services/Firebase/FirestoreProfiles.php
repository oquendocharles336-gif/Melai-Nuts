<?php

namespace App\Services\Firebase;

use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * The app's account profile documents (Firestore users/{uid}: email, name, role, branch,
 * isActive, createdAt), written through the Firestore REST API WITH THE OWNER'S OWN ID TOKEN.
 * So firestore.rules decide exactly as for the app's User Management screen: only an active
 * owner may create a staff/owner profile, staff need a branch. The website has no
 * service account and cannot bypass those rules.
 */
class FirestoreProfiles
{
    private const DENIED = 'Firestore refused access to the app profile. Your own app account must be an active owner with a profile in Firestore (users/<your uid>, role "owner", isActive true).';

    public function __construct(private FirebaseConfig $config) {}

    /**
     * Create users/{uid} (fails if it exists). Returns 'created' or 'exists'.
     *
     * @throws FirebaseAuthException
     */
    public function create(string $ownerIdToken, string $uid, string $email, string $name, string $role, ?string $branch): string
    {
        $doc = $this->docName($uid);
        $fields = [
            'email' => ['stringValue' => $email],
            'name' => ['stringValue' => mb_substr($name, 0, 100)],
            'role' => ['stringValue' => $role],
            'isActive' => ['booleanValue' => true],
        ];
        if ($branch !== null) {
            $fields['branch'] = ['stringValue' => $branch];
        }

        $r = $this->send(fn () => Http::withToken($ownerIdToken)->timeout(15)->acceptJson()
            ->post($this->base().':commit', ['writes' => [[
                'update' => ['name' => $doc, 'fields' => $fields],
                'updateTransforms' => [['fieldPath' => 'createdAt', 'setToServerValue' => 'REQUEST_TIME']],
                'currentDocument' => ['exists' => false],
            ]]]));

        if ($r->successful()) {
            return 'created';
        }
        $status = strtoupper((string) $r->json('error.status', ''));
        if ($status === 'ALREADY_EXISTS' || ($status === 'FAILED_PRECONDITION' && str_contains((string) $r->json('error.message'), 'exist'))) {
            return 'exists';
        }
        Log::warning('[firestore] profile write refused', ['http' => $r->status(), 'status' => $status]);

        throw new FirebaseAuthException(
            $r->serverError() ? FirebaseAuthException::NETWORK : FirebaseAuthException::UNEXPECTED,
            $status === 'PERMISSION_DENIED'
                ? self::DENIED
                : 'Could not create the app profile in Firestore ('.($status ?: 'HTTP '.$r->status()).').',
            $status ?: null);
    }

    /** users/{uid} fields as plain values, or null when the document does not exist. */
    public function get(string $ownerIdToken, string $uid): ?array
    {
        $r = $this->send(fn () => Http::withToken($ownerIdToken)->timeout(15)->acceptJson()->get($this->base().'/users/'.rawurlencode($uid)));
        if ($r->status() === 404) {
            return null;
        }
        if ($r->status() === 403) {
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, self::DENIED, 'PERMISSION_DENIED');
        }
        if ($r->failed()) {
            throw new FirebaseAuthException($r->serverError() ? FirebaseAuthException::NETWORK : FirebaseAuthException::UNEXPECTED, 'Could not read the app profile in Firestore.');
        }

        return collect((array) $r->json('fields', []))->map(fn ($v) => is_array($v) ? reset($v) : $v)->all();
    }

    /**
     * users/{uid}.isActive (owners may change it, firestore.rules). This is what the app's sign-in
     * check (functions/lib/sign-in-policy.js) and its rules read. Returns false when the account has
     * no profile document (nothing to block in Firestore).
     */
    public function setActive(string $ownerIdToken, string $uid, bool $active): bool
    {
        $r = $this->send(fn () => Http::withToken($ownerIdToken)->timeout(15)->acceptJson()
            ->patch($this->base().'/users/'.rawurlencode($uid).'?updateMask.fieldPaths=isActive&currentDocument.exists=true',
                ['fields' => ['isActive' => ['booleanValue' => $active]]]));
        if ($r->successful()) {
            return true;
        }
        $status = strtoupper((string) $r->json('error.status', ''));
        if ($r->status() === 404 || $status === 'NOT_FOUND' || ($status === 'FAILED_PRECONDITION' && str_contains(strtolower((string) $r->json('error.message')), 'exist'))) {
            return false;
        }
        Log::warning('[firestore] isActive write refused', ['http' => $r->status(), 'status' => $status]);
        throw new FirebaseAuthException($r->serverError() ? FirebaseAuthException::NETWORK : FirebaseAuthException::UNEXPECTED,
            $status === 'PERMISSION_DENIED' ? self::DENIED : 'Could not update the app profile in Firestore ('.($status ?: 'HTTP '.$r->status()).').',
            $status ?: null);
    }

    /** Delete users/{uid} (rollback of a failed registration; firestore.rules allow owners). */
    public function delete(string $ownerIdToken, string $uid): void
    {
        $r = $this->send(fn () => Http::withToken($ownerIdToken)->timeout(15)->acceptJson()->delete($this->base().'/users/'.rawurlencode($uid)));
        if ($r->failed() && $r->status() !== 404) {
            throw new FirebaseAuthException(FirebaseAuthException::UNEXPECTED, 'Could not delete the app profile in Firestore.');
        }
    }

    private function base(): string
    {
        return 'https://firestore.googleapis.com/v1/projects/'.rawurlencode((string) $this->config->projectId()).'/databases/(default)/documents';
    }

    private function docName(string $uid): string
    {
        return 'projects/'.$this->config->projectId().'/databases/(default)/documents/users/'.$uid;
    }

    private function send(\Closure $request)
    {
        try {
            return $request();
        } catch (ConnectionException $e) {
            throw new FirebaseAuthException(FirebaseAuthException::NETWORK, 'Could not reach Firestore. Please try again in a moment.');
        }
    }
}

<?php

namespace App\Services\Auth;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Models\User;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirestoreProfiles;
use App\Services\Supabase\SupabaseGateway;

/**
 * Which side of the website a signed-in Melai Nuts account belongs to, decided on the server from
 * the account itself (never from the page it signed in on):
 *
 *   Firestore users/{uid}.role (what the app itself reads at sign-in)
 *     customer          -> CUSTOMER  (the shop; never the admin sign-in steps)
 *     staff / owner     -> STAFF     (the admin sign-in steps: link, two-step, approval)
 *     delivery          -> RIDER     (refused: riders use the app)
 *   no Firestore profile yet:
 *     a website login or a staff/owner row already knows this account -> STAFF
 *     otherwise                                                        -> NEW_CUSTOMER (a sign-up
 *       that never finished the email step)
 */
class AccountKind
{
    public const CUSTOMER = 'customer';

    public const STAFF = 'staff';

    public const RIDER = 'rider';

    public const NEW_CUSTOMER = 'new_customer';

    public function __construct(private FirestoreProfiles $firestore, private SupabaseGateway $gateway) {}

    /**
     * @return array{0: string, 1: ?array} [kind, Firestore profile or null]
     *
     * @throws FirebaseAuthException when Firestore cannot be read (network, configuration)
     */
    public function of(string $idToken, array $claims): array
    {
        $profile = $this->firestore->get($idToken, (string) $claims['sub']);
        $role = (string) ($profile['role'] ?? '');

        return match (true) {
            $role === 'customer' => [self::CUSTOMER, $profile],
            in_array($role, ['staff', 'owner'], true) => [self::STAFF, $profile],
            $role === 'delivery' => [self::RIDER, $profile],
            $profile !== null => [self::STAFF, $profile],          // an unknown role: the admin steps refuse it with their reason
            $this->knownAsStaff($claims) => [self::STAFF, null],
            default => [self::NEW_CUSTOMER, null],
        };
    }

    private function knownAsStaff(array $claims): bool
    {
        $email = mb_strtolower(trim((string) ($claims['email'] ?? '')));
        if (User::where('firebase_uid', $claims['sub'])->orWhere(fn ($q) => $q->where('email', $email)->whereIn('role', User::WEBSITE_ROLES))->exists()) {
            return true;
        }
        foreach (['owner', 'staff'] as $role) {
            try {
                if (($this->gateway->staffUidForEmail($email, $role)['status'] ?? 'none') !== 'none') {
                    return true;
                }
            } catch (BackendUnavailableException|BackendActionException) {
                // Can't tell: take the admin steps, which explain exactly what is wrong.
                return true;
            }
        }

        return false;
    }
}

<?php

namespace App\Services\Shop;

/**
 * The customer's pickup branch, chosen automatically with the app's rules
 * (lib/core/services/branch_choice.dart): the nearest open branch from the browser's location,
 * else the only open branch, else the branch of the last order, else the saved branch.
 * A branch changes only when the new one is at least 1 km closer (no flip-flopping on GPS drift).
 */
class ShopBranch
{
    public const KEY = 'shop_branch';

    public const SWITCH_MARGIN_KM = 1.0;

    public function __construct(
        private ShopCatalog $catalog,
        private CustomerSession $customer,
        private SupabaseRest $rest,
    ) {}

    /** The current branch, worked out without location when possible. */
    public function current(): ?array
    {
        $saved = session(self::KEY);
        if (is_array($saved) && ($branch = $this->safeBranch($saved['id'] ?? null))) {
            return $branch + ['reason' => $saved['reason'] ?? 'saved', 'distance_km' => $saved['distance_km'] ?? null];
        }

        return $this->resolveWithoutLocation();
    }

    public function currentId(): ?string
    {
        return $this->current()['id'] ?? null;
    }

    /**
     * Pick the nearest open branch to the browser's location. Returns [old id, new branch]
     * so the caller can move the cart when the branch changed.
     */
    public function chooseFromLocation(float $lat, float $lng): array
    {
        $oldId = $this->currentId();
        $nearest = null;
        $nearestKm = INF;
        $currentKm = null;
        foreach ($this->catalog->branches() as $b) {
            $km = self::distanceKm($lat, $lng, $b);
            if ($km === null) {
                continue;
            }
            if ($b['id'] === $oldId) {
                $currentKm = $km;
            }
            if ($km < $nearestKm) {
                $nearest = $b;
                $nearestKm = $km;
            }
        }
        if ($nearest === null) {
            return [$oldId, $this->current()];
        }
        if ($currentKm !== null && $currentKm - $nearestKm < self::SWITCH_MARGIN_KM) {
            $this->remember($oldId, 'nearest', $currentKm);

            return [$oldId, $this->current()];
        }
        $this->remember($nearest['id'], 'nearest', $nearestKm);

        return [$oldId, $this->current()];
    }

    /** Straight-line distance in km, or null when the branch has no map pin. */
    public static function distanceKm(float $lat, float $lng, array $branch): ?float
    {
        $bLat = $branch['latitude'] ?? null;
        $bLng = $branch['longitude'] ?? null;
        if ($bLat === null || $bLng === null || abs($bLat) > 90 || abs($bLng) > 180 || ($bLat == 0 && $bLng == 0)) {
            return null;
        }
        $r = 6371.0;
        $dLat = deg2rad($bLat - $lat);
        $dLng = deg2rad($bLng - $lng);
        $a = sin($dLat / 2) ** 2 + cos(deg2rad($lat)) * cos(deg2rad($bLat)) * sin($dLng / 2) ** 2;

        return 2 * $r * asin(min(1.0, sqrt($a)));
    }

    public function forget(): void
    {
        session()->forget(self::KEY);
    }

    // ------------------------------------------------------------------------------------------

    private function resolveWithoutLocation(): ?array
    {
        try {
            $open = $this->catalog->branches();
        } catch (ShopException) {
            return null;
        }
        if (count($open) === 1) {
            $this->remember($open[0]['id'], 'only');

            return $open[0] + ['reason' => 'only', 'distance_km' => null];
        }
        if ($this->customer->check()) {
            try {
                $token = $this->customer->idToken();
                $uid = (string) $this->customer->uid();
                $last = $this->rest->select('orders', [
                    'select' => 'branch_id', 'firebase_uid' => 'eq.'.$uid, 'status' => 'neq.cancelled',
                    'branch_id' => 'not.is.null', 'order' => 'created_at.desc', 'limit' => 1,
                ], $token);
                if (($b = $this->safeBranch($last[0]['branch_id'] ?? null)) !== null) {
                    $this->remember($b['id'], 'last_order');

                    return $b + ['reason' => 'last_order', 'distance_km' => null];
                }
                $profile = $this->rest->select('customer_profiles', ['select' => 'default_branch_id', 'firebase_uid' => 'eq.'.$uid], $token);
                if (($b = $this->safeBranch($profile[0]['default_branch_id'] ?? null)) !== null) {
                    $this->remember($b['id'], 'saved');

                    return $b + ['reason' => 'saved', 'distance_km' => null];
                }
            } catch (ShopException) {
                return null;
            }
        }

        return null;
    }

    private function safeBranch(?string $id): ?array
    {
        if (! is_string($id) || $id === '') {
            return null;
        }
        try {
            return $this->catalog->branch($id);
        } catch (ShopException) {
            return null;
        }
    }

    /** Keep the choice for this visit and, for a signed-in customer, as their saved branch (like the app). */
    private function remember(?string $id, string $reason, ?float $km = null): void
    {
        if ($id === null) {
            return;
        }
        $before = session(self::KEY.'.id');
        session()->put(self::KEY, ['id' => $id, 'reason' => $reason, 'distance_km' => $km !== null ? round($km, 1) : null]);
        if ($before !== $id && $this->customer->check()) {
            try {
                $this->rest->update('customer_profiles', ['firebase_uid' => 'eq.'.$this->customer->uid()], ['default_branch_id' => $id], $this->customer->idToken());
            } catch (ShopException) {
                // Best effort: the choice still applies for this visit.
            }
        }
    }
}

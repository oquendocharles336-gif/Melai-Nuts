<?php

namespace App\Services\Supabase;

use App\Models\User;
use App\Services\ActivityLogger;
use Carbon\Carbon;

/**
 * Loyalty pages on top of the app's real ledger (loyalty_accounts / loyalty_transactions).
 * Balances are never computed or stored here: the database keeps them, and every change
 * is an appended ledger entry made by an owner-only function.
 */
class SupabaseLoyalty
{
    /** ledger source -> page type */
    private const TYPES = ['order_earn' => 'earned', 'order_return' => 'returned', 'order_redeem' => 'redeemed',
        'order_clawback' => 'refunded', 'admin_adjust' => 'adjusted'];

    public function __construct(private SupabaseRepository $repo) {}

    public function members(?string $search): array
    {
        return array_map(fn ($m) => [
            'id' => $m['id'], 'name' => $m['name'], 'email' => $m['email'], 'cardNumber' => $m['card_number'] ?: '—',
            'tier' => null, 'earned' => (int) $m['earned'], 'redeemed' => (int) $m['redeemed'], 'refunded' => (int) $m['refunded'],
            'adjusted' => (int) $m['adjusted'], 'balance' => (int) $m['balance'], 'lifetime' => (int) $m['lifetime'],
        ], $this->repo->loyaltyMembers($search ?: null));
    }

    public function find(string $firebaseUid): ?array
    {
        $m = $this->repo->loyaltyMember($firebaseUid);
        if (! $m) {
            return null;
        }

        // Oldest first (the view reverses it).
        $history = collect($m['history'] ?? [])->reverse()->map(fn ($h) => [
            'type' => self::TYPES[$h['source'] ?? ''] ?? ($h['type'] === 'earn' ? 'earned' : 'redeemed'),
            'points' => (int) $h['points'], 'order_id' => $h['order_id'],
            'reason' => ($h['source'] ?? null) === 'admin_adjust' ? preg_replace('/^Adjustment by Melai Nuts: /', '', $h['description']) : $h['description'],
            'at' => Carbon::parse($h['created_at'])->setTimezone(config('app.timezone')), 'source' => 'app',
        ])->values()->all();
        $sum = fn (string $type) => (int) collect($history)->where('type', $type)->sum('points');

        return [
            'id' => $m['id'], 'name' => $m['name'], 'email' => $m['email'], 'cardNumber' => $m['card_number'] ?: '—', 'tier' => null,
            'balance' => (int) $m['balance'], 'lifetime' => (int) $m['lifetime'],
            'earned' => $sum('earned'), 'redeemed' => abs($sum('redeemed')), 'refunded' => abs($sum('refunded')), 'adjusted' => $sum('adjusted'),
            'pointsHistory' => $history,
        ];
    }

    public function settings(): array
    {
        return $this->repo->loyaltySettings();
    }

    public function updateSettings(array $v, User $admin): void
    {
        $this->repo->updateLoyaltySettings((float) $v['earn_pesos_per_point'], (float) $v['points_per_peso'], (float) $v['max_discount_percent']);
        ActivityLogger::log('loyalty.settings_updated', 'Updated loyalty settings in the app', $admin, $v + ['source' => 'supabase']);
    }

    /** @return bool false when this exact request was already applied (double submit). */
    public function adjust(array $member, int $points, string $reason, string $requestKey, User $admin): bool
    {
        $result = $this->repo->adjustLoyalty($member['id'], $points, $reason, $requestKey);
        if ($result['duplicate'] ?? false) {
            return false;
        }
        ActivityLogger::log('loyalty.adjusted', ($points > 0 ? "+{$points}" : $points)." pts for {$member['name']}: {$reason}", $admin, [
            'member_id' => $member['id'], 'points' => $points, 'reason' => $reason, 'balance_after' => $result['balance'] ?? null, 'source' => 'supabase',
        ]);

        return true;
    }
}

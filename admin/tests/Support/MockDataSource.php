<?php

namespace Tests\Support;

use App\Contracts\DataSource;
use Carbon\Carbon;

/** TEST-ONLY fake, stable data for the automated tests (DATA_SOURCE=mock under APP_ENV=testing). Never bound outside the test suite. */
class MockDataSource implements DataSource
{
    private const PRODUCTS = [['Roasted Peanuts', 120], ['Garlic Peanuts', 100], ['Peanut Brittle', 80], ['Peanut Butter', 60], ['Chili Peanuts', 90]];

    /** Deterministic per-branch multiplier so sales land in Low/Average/High without being random each load. */
    private function multiplier(string $branchId): float
    {
        $mults = [1.2, 0.65, 0.95, 1.05, 0.5]; // cycles if there are more branches than entries
        $branches = collect(MockPlatform::BRANCHES)->pluck('id')->values();
        $i = $branches->search($branchId);
        return $mults[$i % count($mults)] ?? 1.0;
    }

    public function orders(Carbon $from, Carbon $to): array
    {
        mt_srand(2026);
        $orders = [];
        $methods = ['gcash', 'maya', 'card', 'cod'];
        $customers = ['Liza Gomez', 'Mark Villanueva', 'Rhea Santos', 'Jun Dizon', 'Carla Mendoza', 'Paolo Ramos'];
        $reasons = ['Item arrived damaged', 'Wrong item delivered', 'Changed my mind', 'Order took too long', 'Missing items in the order'];
        foreach (MockPlatform::BRANCHES as $b) {
            $mult = $this->multiplier($b['id']);
            for ($d = 0; $d < 35; $d++) {
                $day = now()->startOfDay()->subDays($d);
                for ($i = 0, $n = mt_rand(8, 12); $i < $n; $i++) {
                    $at = $day->copy()->addMinutes(mt_rand(480, 1200));
                    if ($at->gt(now()) || $at->lt($from) || $at->gt($to)) { continue; }
                    $roll = mt_rand(1, 100);
                    $total = round(mt_rand(150, 900) * $mult);
                    // Ranges are mutually exclusive so a refund can never be attached to an unpaid/failed order:
                    // 1-82 paid, 83-90 pending, 91-94 failed, 95-97 paid+refund requested, 98-100 paid+refunded.
                    $hasRefund = $roll > 94;
                    $refunded = $roll > 97;
                    $orders[] = [
                        'id' => $b['id'].'-'.$d.'-'.$i, 'branch' => $b['id'], 'items' => ['Roasted Peanuts x2'], 'total' => $total,
                        'status' => 'completed', 'createdAt' => $at,
                        'paymentStatus' => $roll <= 82 || $hasRefund ? 'paid' : ($roll <= 90 ? 'pending' : 'failed'),
                        'paymentMethod' => $methods[array_rand($methods)],
                        'paidAt' => $at, 'refundStatus' => $refunded ? 'refunded' : ($hasRefund ? 'requested' : null),
                        'refundAmount' => $hasRefund ? $total : null,
                        'customer' => $customers[array_rand($customers)],
                        'refundReason' => $hasRefund ? $reasons[array_rand($reasons)] : null,
                        'refundPhoto' => null, // CHANGE: Firestore will provide a real photo URL here
                    ];
                }
            }
        }
        return $orders;
    }

    public function stock(): array
    {
        $fills = [0.9, 0.3, 0.65, 0.5, 0.8]; // cycles; makes one branch clearly the lowest
        $branches = collect(MockPlatform::BRANCHES)->pluck('id')->values();
        $out = [];
        foreach ($branches as $idx => $branch) {
            $f = $fills[$idx % count($fills)];
            foreach (self::PRODUCTS as $k => [$name, $par]) {
                $wobble = [1.0, 0.8, 1.2, 0.5, 1.1][$k];
                $out[$branch][] = ['product' => $name, 'par' => $par, 'reorder' => (int) round($par * 0.3), 'qty' => (int) round($par * min(1, $f * $wobble))];
            }
        }
        return $out;
    }

    public function loyalty(): array { return ['members' => 1248, 'issued_month' => 84210, 'redeemed_month' => 31500, 'reversed_month' => 420]; }

    /** sales_overview() shape from the fixture orders (see SalesFixture; the real figures come from the database). */
    public function salesOverview(string $from, string $to, ?string $branchId = null): ?array
    {
        $rows = array_map(fn ($o) => [
            'branch' => $o['branch'], 'day' => $o['createdAt']->toDateString(),
            'paid' => in_array($o['paymentStatus'], ['paid', 'refunded'], true), 'gross' => (float) $o['total'],
            'refund' => $o['refundStatus'] === 'refunded' ? (float) $o['refundAmount'] : 0.0, 'refund_day' => $o['createdAt']->toDateString(),
            'pending_refund' => $o['refundStatus'] === 'requested' ? (float) $o['refundAmount'] : 0.0,
            'method' => $o['paymentMethod'], 'channel' => 'pickup',
        ], array_values(array_filter($this->orders(Carbon::parse($from)->startOfDay(), Carbon::parse($to)->endOfDay()),
            fn ($o) => $branchId === null || $o['branch'] === $branchId)));
        $branches = array_values(array_filter(MockPlatform::BRANCHES, fn ($b) => $branchId === null || $b['id'] === $branchId));

        return SalesFixture::overview($rows, $from, $to, $branches);
    }

    /** Same customer names used in orders() so a refund can look up "who earned these points" by name. */
    public function loyaltyMembers(): array
    {
        mt_srand(4042);
        $customers = [
            ['name' => 'Liza Gomez', 'email' => 'liza.gomez@example.com'],
            ['name' => 'Mark Villanueva', 'email' => 'mark.villanueva@example.com'],
            ['name' => 'Rhea Santos', 'email' => 'rhea.santos@example.com'],
            ['name' => 'Jun Dizon', 'email' => 'jun.dizon@example.com'],
            ['name' => 'Carla Mendoza', 'email' => 'carla.mendoza@example.com'],
            ['name' => 'Paolo Ramos', 'email' => 'paolo.ramos@example.com'],
        ];
        $tiers = ['Bronze', 'Silver', 'Gold'];

        $members = [];
        foreach ($customers as $i => $c) {
            $history = [];
            for ($o = 0, $n = mt_rand(4, 9); $o < $n; $o++) {
                $points = mt_rand(15, 90);
                $history[] = [
                    'orderId' => 'branch-calamba-'.mt_rand(0, 34).'-'.$o.'-m'.$i,
                    'type' => 'earned', 'points' => $points, 'at' => now()->subDays(mt_rand(1, 120)),
                ];
                if (mt_rand(1, 100) <= 25) {
                    $history[] = ['orderId' => null, 'type' => 'redeemed', 'points' => -1 * mt_rand(10, 50), 'at' => now()->subDays(mt_rand(1, 100))];
                }
            }
            $members[] = [
                'id' => 'member-'.($i + 1), 'name' => $c['name'], 'email' => $c['email'],
                'cardNumber' => 'MN-'.str_pad((string) (1000 + $i * 37), 6, '0', STR_PAD_LEFT),
                'tier' => $tiers[$i % count($tiers)],
                'pointsHistory' => collect($history)->sortBy('at')->values()->all(),
            ];
        }

        return $members;
    }

    public function pendingRefunds(): int { return 3; }
}

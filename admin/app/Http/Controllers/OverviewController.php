<?php

namespace App\Http\Controllers;

use App\Services\OrderQueryService;
use App\Services\OverviewService;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;

/**
 * JSON for the redesigned Overview (range-aware: 7 / 30 / 90 days) and the sidebar badges.
 * Read-only; same access rules as the dashboard page (auth, active, has.access).
 */
class OverviewController extends Controller
{
    public function overview(Request $request, OverviewService $overview): JsonResponse
    {
        $branch = is_string($request->query('branch')) ? $request->query('branch') : null;

        return response()->json($overview->overview((int) $request->query('range', 30), $branch, $request->boolean('fresh')));
    }

    /** Command palette: orders (id / customer) and products (name / SKU) matching ?q=. */
    public function search(Request $request, OrderQueryService $orders, Platform $platform): JsonResponse
    {
        $q = mb_strtolower(trim((string) $request->query('q', '')));
        if (mb_strlen($q) < 2) {
            return response()->json([]);
        }
        $ids = array_column($platform->branches(), 'id');
        $found = collect($orders->cachedOrders())
            ->filter(fn ($o) => in_array($o['branch'] ?? null, $ids, true)
                && (str_contains(mb_strtolower($o['id']), $q) || str_contains(mb_strtolower((string) ($o['customer'] ?? '')), $q)))
            ->sortByDesc(fn ($o) => $o['createdAt']?->getTimestamp() ?? 0)->take(6)
            ->map(fn ($o) => ['type' => 'Orders', 'label' => $o['id'].' · '.($o['customer'] ?? '—'),
                'hint' => '₱'.number_format((float) $o['total'], 2), 'url' => route('orders.index', ['open' => $o['id']])])->values();

        if ($platform->isSupabase()) {
            try {
                $found = $found->concat(collect(\App\Support\Swr::remember('products-list', \App\Support\Swr::fresh(), \App\Support\Swr::stale(), fn () => app(SupabaseRepository::class)->products()))
                    ->filter(fn ($p) => str_contains(mb_strtolower($p['name'].' '.($p['sku'] ?? '')), $q))->take(6)
                    ->map(fn ($p) => ['type' => 'Products', 'label' => $p['name'], 'hint' => $p['category'] ?? '',
                        'url' => route('section', ['slug' => 'inventory', 'q' => $p['name']])])->values());
            } catch (\Throwable) {
                // products are optional in search; orders still show
            }
        }

        return response()->json($found->values());
    }

    /**
     * Live pages ask this every few seconds instead of reloading themselves: one tiny database
     * read (SupabaseRepository::pulse). When it differs from the last one seen for this account,
     * every cached answer is dropped (AdminActions::bump) and 'changed' tells the page to reload
     * its content once. Changes made on this website change 'sig' through the data version.
     * Without the database (or if the read fails) the version plus the current minute is used,
     * so pages still refresh about once a minute, from the cache.
     */
    public function pulse(Platform $platform): JsonResponse
    {
        $changed = false;
        $data = null;
        $off = 'melai:pulse-off:'.\App\Support\Swr::scope();
        if ($platform->isSupabase() && ! Cache::has($off)) {
            try {
                $data = app(SupabaseRepository::class)->pulse();
            } catch (\Throwable $e) {
                report($e);
                Cache::put($off, true, 600);   // e.g. a missing permission: don't retry every few seconds
            }
        }
        if ($data !== null) {
            $key = 'melai:pulse:'.\App\Support\Swr::scope();
            $seen = Cache::get($key);
            if ($seen !== $data) {
                Cache::put($key, $data, 86400);
                if ($seen !== null) {
                    \App\Services\AdminActions::bump();
                    $changed = true;
                }
            }
        }
        $sig = substr(sha1(($data ?? 't'.intdiv(time(), 60)).'|v'.\App\Services\AdminActions::version()), 0, 16);

        return response()->json(['sig' => $sig, 'changed' => $changed])->header('Cache-Control', 'no-store, private');
    }

    public function counts(Request $request, OverviewService $overview): JsonResponse
    {
        $counts = $overview->navCounts($request->boolean('fresh'));
        if (! $request->user()->isAdmin()) {
            $counts['refunds'] = 0; // the Refunds page is admin-only, so is its badge
        }

        return response()->json($counts);
    }
}

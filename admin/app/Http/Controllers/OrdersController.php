<?php

namespace App\Http\Controllers;

use App\Services\ActivityLogger;
use App\Services\AdminActions;
use App\Services\OrderQueryService;
use App\Services\OverviewService;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

/**
 * Orders page of the redesigned admin: every order of the last melai.supabase.order_window_days
 * days in the branches the account may see, a detail drawer, "Move to next stage" (the app's own
 * staff_update_order_status) and "New order" (an in-store sale through staff_create_pos_sale).
 *
 * Delivery orders are listed read-only (channel label "delivery"): they cannot be advanced or
 * created here. Confirming, dispatching and completing them happens only in the Melai Nuts app.
 */
class OrdersController extends Controller
{
    // Resolved per call, not held by the controller: Laravel may reuse a controller instance across
    // requests (test client, Octane), and these services are per request (scoped), so a held one
    // would keep a previous request's order list and account check.
    private function orders(): OrderQueryService
    {
        return app(OrderQueryService::class);
    }

    private function platform(): Platform
    {
        return app(Platform::class);
    }

    public function index(Request $request)
    {
        // Account check on every request; the rows themselves come from the per-account cache
        // (shared 90-day order window, in ONE round trip when missing).
        $branches = $this->platform()->branches();
        $rows = \App\Support\Swr::remember('orders-page', \App\Support\Swr::fresh(), \App\Support\Swr::stale(), function () {
            if ($this->platform()->isSupabase()) {
                app(SupabaseRepository::class)->prefetch($this->orders()->windowReads());
            }

            return $this->rows();
        });

        return view('orders.index', [
            'orders' => $rows,
            'branches' => $branches,
            'liveData' => $this->platform()->isSupabase(),
            'open' => is_string($request->query('open')) ? $request->query('open') : null,
            'windowDays' => (int) config('melai.supabase.order_window_days', 90),
        ]);
    }

    /**
     * CSV of the orders the page lists, with the page's stage chip (?status=), branch and search
     * (?q=: order, customer or product), the same matching as the screen. Uses the same cached rows.
     */
    public function export(Request $request)
    {
        $status = (string) $request->query('status', 'all');
        $branch = (string) $request->query('branch', '');
        $q = \App\Support\ListTools::query($request);
        $rows = \App\Support\Swr::remember('orders-page', \App\Support\Swr::fresh(), \App\Support\Swr::stale(), fn () => $this->rows());
        $rows = array_filter($rows, fn ($r) => ($status === 'all' || ($status === 'other' ? $r['stage'] === null : $r['stage'] === $status))
            && ($branch === '' || $r['branch'] === $branch));
        $rows = \App\Support\ListTools::search($rows, $q, fn ($r) => $r['id'].' '.$r['customer'].' '.implode(' ', $r['items']));
        ActivityLogger::log('orders.exported', 'Exported orders ('.count($rows).' rows)', $request->user(), compact('status', 'branch', 'q'));

        return \App\Support\ListTools::csv('melai-orders-'.now('Asia/Manila')->format('Y-m-d').'.csv', [
            'order' => fn ($r) => $r['id'], 'placed_at' => fn ($r) => $r['placedAt'], 'branch' => fn ($r) => $r['branchName'],
            'channel' => fn ($r) => $r['isPos'] ? 'in-store' : ($r['isDelivery'] ? 'delivery' : 'pickup'), 'customer' => fn ($r) => $r['customer'],
            'items' => fn ($r) => implode('; ', $r['items']), 'total' => fn ($r) => $r['total'], 'payment_method' => fn ($r) => $r['method'],
            'payment_status' => fn ($r) => $r['payment'], 'status' => fn ($r) => $r['statusLabel'], 'refunded' => fn ($r) => $r['refunded'],
        ], $rows);
    }

    /** POST /orders/{id}/advance  {from: <status the screen showed>} */
    public function advance(Request $request, string $orderId, AdminActions $actions): JsonResponse
    {
        abort_unless(preg_match('/^[A-Za-z0-9_-]{1,80}$/', $orderId), 404);
        $this->needsDatabase();
        $from = (string) $request->input('from', '');

        $this->orders()->refresh();
        $order = $this->orders()->find($orderId);
        abort_if(! $order || ! collect($this->platform()->branches())->pluck('id')->contains($order['branch']), 404);
        if ($from !== '' && $from !== $order['status']) {
            // Someone else moved it in the meantime: show the real state instead of skipping a step.
            return response()->json(['message' => 'This order was updated elsewhere. Showing its current status.',
                'order' => $this->row($order)], 409);
        }
        if ($order['isDelivery'] ?? false) {
            // Delivery orders move only in the Melai Nuts app (staff portal / delivery runs).
            return response()->json(['message' => 'Delivery orders are handled in the Melai Nuts app.', 'order' => $this->row($order)], 422);
        }
        $next = AdminActions::nextStatus($order['status'], (bool) ($order['isDelivery'] ?? false));
        if (! $next) {
            return response()->json(['message' => 'This order has no next stage.', 'order' => $this->row($order)], 422);
        }

        $actions->updateOrderStatus($orderId, $next);
        ActivityLogger::log('order.status_changed', "Moved order {$orderId} from {$order['status']} to {$next}", null,
            ['order_id' => $orderId, 'from' => $order['status'], 'to' => $next, 'source' => 'supabase']);

        $this->orders()->refresh();
        $fresh = $this->orders()->find($orderId) ?? array_merge($order, ['status' => $next]);

        return response()->json(['message' => 'Order '.$orderId.' is now '.OverviewService::orderStatusLabel($fresh['status']).'.',
            'order' => $this->row($fresh)]);
    }

    /** Branches for the New order form (loaded when it opens, so page shells need no database call). */
    public function branches(): JsonResponse
    {
        return response()->json(collect($this->platform()->branches())->map(fn ($b) => ['id' => $b['id'], 'name' => $b['name']])->values());
    }

    /** Variants with price and stock in one branch, for the New order form. */
    public function catalog(Request $request, SupabaseRepository $repo): JsonResponse
    {
        $this->needsDatabase();
        $branchId = $this->branch($request->query('branch'));
        $inv = $repo->inventory($branchId);

        return response()->json(collect($inv['items'] ?? [])->map(fn ($i) => [
            'variant_id' => $i['variant_id'],
            'name' => $i['product_name'].(in_array($i['variant_label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$i['variant_label']),
            'sku' => $i['sku'] ?? null, 'price' => (float) $i['price'], 'stock' => (int) $i['quantity'],
        ])->values());
    }

    /** POST /orders  In-store sale (walk-in), recorded by the app's own POS function. */
    public function store(Request $request, AdminActions $actions): JsonResponse
    {
        $this->needsDatabase();
        $v = $request->validate([
            'branch' => ['required', 'string'],
            'items' => ['required', 'array', 'min:1', 'max:50'],
            'items.*.variant_id' => ['required', 'uuid'],
            'items.*.quantity' => ['required', 'integer', 'min:1', 'max:1000'],
            'method' => ['required', 'in:cash,gcash,card'],
            'reference' => ['nullable', 'string', 'max:80', 'required_unless:method,cash'],
            'cash_received' => ['nullable', 'numeric', 'min:0', 'max:10000000'],
            'key' => ['required', 'string', 'max:100'],
            // In-store sales only: a delivery order can never be created from the website.
            'type' => ['prohibited'], 'order_type' => ['prohibited'], 'is_delivery' => ['prohibited'],
            'delivery_address' => ['prohibited'], 'delivery_address_id' => ['prohibited'], 'fulfillment' => ['prohibited'],
        ]);
        $branchId = $this->branch($v['branch']);
        $items = collect($v['items'])->map(fn ($i) => ['variant_id' => $i['variant_id'], 'quantity' => (int) $i['quantity']])->all();

        $r = $actions->createPosSale($branchId, $items, $v['method'], $v['reference'] ?? null,
            isset($v['cash_received']) ? (float) $v['cash_received'] : null, 'web:'.Str::limit($v['key'], 90, ''));
        ActivityLogger::log('order.pos_created', 'Recorded in-store sale '.($r['order_id'] ?? ''), null,
            ['order_id' => $r['order_id'] ?? null, 'branch_id' => $branchId, 'source' => 'supabase']);

        return response()->json(['message' => 'Order '.($r['order_id'] ?? '').' recorded.', 'result' => $r]);
    }

    // ---- helpers ---------------------------------------------------------------------------

    private function needsDatabase(): void
    {
        abort_unless($this->platform()->isSupabase(), 503, 'This action needs the Melai Nuts app database.');
    }

    private function branch(mixed $id): string
    {
        $ids = collect($this->platform()->branches())->pluck('id');
        abort_unless(is_string($id) && $ids->contains($id), 422, 'Choose one of your branches.');

        return $id;
    }

    private function rows(): array
    {
        $ids = array_column($this->platform()->branches(), 'id');

        return collect($this->orders()->cachedOrders())
            ->filter(fn ($o) => in_array($o['branch'] ?? null, $ids, true))
            ->sortByDesc(fn ($o) => $o['createdAt']?->getTimestamp() ?? 0)
            ->map(fn ($o) => $this->row($o))->values()->all();
    }

    private function row(array $o): array
    {
        $status = (string) ($o['status'] ?? '');
        $next = AdminActions::nextStatus($status, (bool) ($o['isDelivery'] ?? false));

        return [
            'id' => $o['id'],
            'customer' => $o['customer'] ?? '—',
            'branch' => $o['branch'],
            'branchName' => $o['branchName'] ?? $this->platform()->branchName($o['branch']),
            'status' => $status,
            // A 'refunded' order whose refund covered only part of it is shown as such (from the database's refund summary).
            'statusLabel' => $status === 'refunded' && ($o['refundState'] ?? null) === 'partial' ? 'Partially refunded' : OverviewService::orderStatusLabel($status),
            'tone' => OverviewService::orderTone($status),
            'stage' => OverviewService::STAGES[$status] ?? null,
            'next' => $next, 'nextLabel' => $next ? OverviewService::orderStatusLabel($next) : null,
            'total' => (float) $o['total'],
            'items' => array_values($o['items'] ?? []),
            'placedAt' => $o['createdAt']?->toIso8601String(),
            'isDelivery' => (bool) ($o['isDelivery'] ?? false),
            'isPos' => (bool) ($o['isPos'] ?? false),
            'payment' => $o['paymentStatus'] ?? null,
            'method' => OverviewService::methodLabel((string) ($o['paymentMethod'] ?? '')),
            'refund' => $o['refundStatus'] ?? null,
            // Refund figures computed by the database (null = unknown on an older database, shown as "—").
            'refundState' => $o['refundState'] ?? null,
            'refunded' => $o['refundedAmount'] ?? null,
            'refundedUnits' => $o['refundedUnits'] ?? null,
            'pendingRefund' => $o['pendingRefundAmount'] ?? null,
            'pointsReversed' => $o['pointsReversed'] ?? null,
        ];
    }
}

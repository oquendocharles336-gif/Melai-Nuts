<?php

namespace App\Http\Controllers\Admin;

use App\Http\Requests\MarkPaidRequest;
use App\Http\Controllers\Controller;
use App\Services\ActivityLogger;
use App\Services\OrderQueryService;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use App\Support\ListTools;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;

/** Payments of the app's orders, from the shared database. Admin can confirm cash payments. */
class PaymentController extends Controller
{
    // Per-request (scoped) services are resolved on each use instead of being held by the controller:
    // Laravel can reuse a controller instance across requests (test client, Octane), and a held one
    // would keep a previous request's account check and query results.
    private function orders(): OrderQueryService
    {
        return app(OrderQueryService::class);
    }

    private function platform(): Platform
    {
        return app(Platform::class);
    }

    public function index(Request $request, \App\Contracts\DataSource $data)
    {
        $filters = $request->only(['status', 'method', 'branch', 'from', 'to']);
        $q = ListTools::query($request);
        $orders = collect(ListTools::search($this->orders()->filter($filters), $q, [self::class, 'searchText']))
            ->sortByDesc('createdAt')->values()->all();

        // Totals per method: net sales by payment method from the database (sales_overview), for the
        // chosen days and branch: the same figures as the dashboard and the reports.
        $day = fn ($v) => is_string($v) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $v) ? $v : null;
        $from = $day($filters['from'] ?? null) ?? $this->orders()->range()[0]->copy()->setTimezone('Asia/Manila')->toDateString();
        $to = $day($filters['to'] ?? null) ?? now('Asia/Manila')->toDateString();
        $branch = collect($this->platform()->branches())->pluck('id')->contains($filters['branch'] ?? null) ? $filters['branch'] : null;
        $sales = $to >= $from ? $data->salesOverview($from, $to, $branch) : null;

        return view('admin.payments.index', [
            'orders' => ListTools::paginate($orders, $request, 25),
            'q' => $q,
            'totals' => $sales === null ? null : ($sales['by_method'] ?? []),
            'totalsRange' => [$from, $to],
            'failedOrPending' => collect($orders)->whereIn('effectivePaymentStatus', ['failed', 'pending'])->values()->all(),
            'branches' => $this->platform()->branches(),
            'methods' => $this->platform()->paymentMethods(),
            'cashMethod' => $this->platform()->cashMethod(),
            'liveData' => $this->platform()->isSupabase(),
            'filters' => $filters,
        ]);
    }

    /** CSV of every payment matching the page's filters and search (not just the visible page). */
    public function export(Request $request)
    {
        $q = ListTools::query($request);
        $rows = collect(ListTools::search($this->orders()->filter($request->only(['status', 'method', 'branch', 'from', 'to'])), $q, [self::class, 'searchText']))
            ->sortByDesc('createdAt')->values()->all();
        ActivityLogger::log('payments.exported', 'Exported payments ('.count($rows).' rows)', $request->user(), ['q' => $q] + $request->only(['status', 'method', 'branch', 'from', 'to']));

        return ListTools::csv('melai-payments-'.now('Asia/Manila')->format('Y-m-d').'.csv', [
            'order' => fn ($o) => $o['id'], 'placed_at' => fn ($o) => $o['createdAt'], 'branch' => fn ($o) => $o['branchName'] ?? $o['branch'],
            'customer' => fn ($o) => $o['customer'], 'method' => fn ($o) => $o['paymentMethod'], 'reference' => fn ($o) => $o['paymentReference'] ?? null,
            'amount' => fn ($o) => $o['total'], 'status' => fn ($o) => $o['effectivePaymentStatus'], 'paid_at' => fn ($o) => $o['paidAt'],
            'refunded' => fn ($o) => $o['refundedAmount'] ?? null,
        ], $rows);
    }

    /** What the search box matches: order, customer, branch, method, reference. */
    public static function searchText(array $o): string
    {
        return implode(' ', [$o['id'], $o['customer'] ?? '', $o['branchName'] ?? '', $o['paymentMethod'] ?? '', $o['paymentReference'] ?? '']);
    }

    /** Only admin, only for cash (counter / on delivery), and only once the cash has actually been collected. */
    public function markPaid(MarkPaidRequest $request, string $orderId)
    {
        $order = $this->orders()->find($orderId);
        abort_if(! $order, 404);

        if ($order['paymentMethod'] !== $this->platform()->cashMethod()) {
            throw ValidationException::withMessages(['order' => 'Only cash orders can be marked paid this way.']);
        }
        if ($order['effectivePaymentStatus'] === 'paid') {
            throw ValidationException::withMessages(['order' => 'This order is already marked as paid.']);
        }

        // Same function the staff app uses: locks the order + payment, checks the branch,
        // refuses if already paid/cancelled, notifies the customer. Points are awarded by the
        // database when the order is completed. The success message is shown only after the
        // database confirmed the change (an error is shown otherwise).
        app(SupabaseRepository::class)->confirmPayment($orderId);
        $this->orders()->refresh();
        ActivityLogger::log('payment.cash_confirmed', "Confirmed cash payment for order {$orderId}", null, [
            'order_id' => $orderId, 'amount' => $order['total'], 'by' => $request->user()->id, 'source' => 'supabase',
        ]);

        return back()->with('status', "Order {$orderId} marked as paid.");
    }
}

<?php

namespace App\Http\Controllers;

use App\Http\Requests\CancelPurchaseReceiptRequest;
use App\Http\Requests\SaveSupplierRequest;
use App\Http\Requests\StorePurchaseReceiptRequest;
use App\Http\Requests\UpdatePurchaseReceiptRequest;
use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;
use App\Support\ReceiptTextParser;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

/**
 * Suppliers and purchase receipts with OCR.
 *
 * OCR runs in the browser (Tesseract.js) on the photo the user picks; the text comes here,
 * ReceiptTextParser turns it into a draft, and a person checks every line. Stock is posted only
 * by "Approve" (staff_approve_purchase_receipt). The photo is kept privately on this server
 * (storage/app/private/receipts) as evidence; only users allowed to open the receipt can view it.
 */
class PurchaseReceiptController extends Controller
{
    /** [['id' => variant uuid, 'label' => 'Product · Variant'], ...] */
    private function variants(): array
    {
        return collect($this->repo()->products())->flatMap(fn ($p) => collect($p['variants'] ?? [])->map(fn ($v) => [
            'id' => $v['id'], 'label' => $p['name'].(in_array($v['label'] ?? '', ['', 'Regular'], true) ? '' : ' · '.$v['label']),
        ]))->sortBy('label')->values()->all();
    }

    private function branchIds(): \Illuminate\Support\Collection
    {
        return collect($this->platform()->branches())->pluck('id');
    }

    public function index(Request $request)
    {
        $isOwner = $this->identity()->isOwner();
        $branch = $this->branchIds()->contains($request->query('branch')) ? $request->query('branch') : null;
        if (! $isOwner) {
            $branch = $this->branchIds()->first();
        }
        $status = in_array($request->query('status'), ['draft', 'approved', 'cancelled'], true) ? $request->query('status') : null;

        // SPEED: cached per account like the dashboard (DASHBOARD_CACHE_SECONDS, fresh only: a full page
        // has no background refresh). Any change made on this website (new / approved / cancelled
        // receipt) invalidates it at once; ?fresh=1 reloads.
        $receipts = \App\Support\Swr::remember("receipts-list:$branch:$status", \App\Support\Swr::fresh(), \App\Support\Swr::fresh(),
            fn () => $this->repo()->purchaseReceipts($branch, $status));

        return view('receipts.index', [
            'receipts' => $receipts,
            'branches' => $this->platform()->branches(), 'branch' => $branch, 'status' => $status, 'isOwner' => $isOwner,
        ]);
    }

    public function create()
    {
        return view('receipts.create', ['branches' => $this->platform()->branches(), 'suppliers' => $this->repo()->suppliers()]);
    }

    /** Photo + OCR text -> draft receipt (nothing touches stock here). */
    public function store(StorePurchaseReceiptRequest $request, ReceiptTextParser $parser)
    {
        $data = $request->validated();
        abort_unless($this->branchIds()->contains($data['branch_id']), 403);

        $text = trim((string) ($data['ocr_text'] ?? ''));
        $parsed = $text !== '' ? $parser->parse($text, $this->variants(), $this->repo()->suppliers()) : ['lines' => []];

        $path = null;
        if ($request->hasFile('photo')) {
            $path = $request->file('photo')->store('receipts/'.now()->format('Y/m'), 'local');
        }

        $lines = collect($parsed['lines'])->map(fn ($l) => [
            'raw_text' => $l['raw_text'], 'description' => $l['description'], 'variant_id' => $l['variant_id'],
            'quantity' => $l['quantity'], 'unit_cost' => $l['unit_cost'],
        ])->all();

        $receipt = $this->repo()->savePurchaseReceipt(null, $data['branch_id'],
            $data['supplier_id'] ?? ($parsed['supplier_id'] ?? null),
            $parsed['invoice_no'] ?? null, $this->sanePastDate($parsed['invoice_date'] ?? null), $lines,
            $text !== '' ? 'ocr' : 'manual', $text !== '' ? $text : null,
            isset($data['ocr_confidence']) ? (float) $data['ocr_confidence'] : null, $path, null, $parsed['total'] ?? null);

        ActivityLogger::log('purchase_receipt.draft', "Created draft {$receipt['receipt_code']}".($text !== '' ? ' from OCR' : ''), null,
            ['receipt_id' => $receipt['id'], 'lines' => count($lines)]);

        $msg = $text !== ''
            ? 'OCR read '.count($lines).' item line(s). Check every line against the paper invoice, fill in what is missing, then approve.'
            : 'Draft created. Add the lines from the invoice, then approve.';

        return redirect()->route('receipts.show', $receipt['id'])->with('status', $msg);
    }

    /** An OCR date outside the last two years is almost always a misread: leave it for the reviewer. */
    private function sanePastDate(?string $d): ?string
    {
        if (! $d) {
            return null;
        }
        $date = \Carbon\Carbon::parse($d, 'Asia/Manila');

        return $date->isFuture() || $date->lt(now('Asia/Manila')->subYears(2)) ? null : $d;
    }

    public function show(string $id)
    {
        abort_unless(Str::isUuid($id), 404);
        $receipt = $this->repo()->purchaseReceipt($id);

        return view('receipts.show', [
            'r' => $receipt,
            'variants' => $receipt['status'] === 'draft' ? $this->variants() : [],
            'suppliers' => $this->repo()->suppliers(true),
            'branches' => $this->platform()->branches(),
            'requestKey' => Str::random(32),
        ]);
    }

    /** Save the reviewed draft; with action=approve, also post it to stock. */
    public function update(UpdatePurchaseReceiptRequest $request, string $id)
    {
        abort_unless(Str::isUuid($id), 404);
        $data = $request->validated();
        abort_unless($this->branchIds()->contains($data['branch_id']), 403);

        $lines = collect($data['lines'] ?? [])->map(fn ($l) => [
            'raw_text' => $l['raw_text'] ?? null, 'description' => $l['description'] ?? null,
            'variant_id' => $l['variant_id'] ?? null, 'quantity' => $l['quantity'] ?? null,
            'unit_cost' => $l['unit_cost'] ?? null, 'batch_code' => $l['batch_code'] ?? null,
            'expiration_date' => $l['expiration_date'] ?? null,
        ])->values()->all();

        $receipt = $this->repo()->savePurchaseReceipt($id, $data['branch_id'], $data['supplier_id'] ?? null,
            $data['supplier_invoice_no'] ?? null, $data['invoice_date'] ?? null, $lines,
            notes: $data['notes'] ?? null, invoiceTotal: isset($data['invoice_total']) ? (float) $data['invoice_total'] : null);

        if (($data['action'] ?? 'save') !== 'approve') {
            return redirect()->route('receipts.show', $id)->with('status', 'Draft saved. Nothing has been added to stock yet.');
        }

        $receipt = $this->repo()->approvePurchaseReceipt($id, $data['request_key'] ?? Str::random(32));
        ActivityLogger::log('purchase_receipt.approved', "Approved {$receipt['receipt_code']} — stock received", null,
            ['receipt_id' => $id, 'lines' => count($receipt['lines'] ?? []), 'total' => $receipt['lines_total'] ?? null]);

        return redirect()->route('receipts.show', $id)->with('status', 'Approved. '.count($receipt['lines'] ?? []).' batch(es) were added to stock at '.$receipt['branch_name'].'.');
    }

    public function cancel(CancelPurchaseReceiptRequest $request, string $id)
    {
        abort_unless(Str::isUuid($id), 404);
        $data = $request->validated();
        $receipt = $this->repo()->cancelPurchaseReceipt($id, $data['reason']);
        ActivityLogger::log('purchase_receipt.cancelled', "Cancelled draft {$receipt['receipt_code']}", null, ['receipt_id' => $id, 'reason' => $data['reason']]);

        return redirect()->route('receipts.show', $id)->with('status', 'Draft cancelled.');
    }

    /** The scanned photo, only for users the database lets open the receipt. */
    public function image(string $id)
    {
        abort_unless(Str::isUuid($id), 404);
        $path = $this->repo()->purchaseReceipt($id)['document_path'] ?? null;
        abort_unless($path && str_starts_with($path, 'receipts/') && ! str_contains($path, '..') && Storage::disk('local')->exists($path), 404);

        return Storage::disk('local')->response($path, null, ['Cache-Control' => 'private, max-age=600', 'X-Content-Type-Options' => 'nosniff']);
    }

    // ---- suppliers ------------------------------------------------------------------------

    public function suppliers()
    {
        return view('receipts.suppliers', ['suppliers' => $this->repo()->suppliers(true)]);
    }

    public function saveSupplier(SaveSupplierRequest $request, ?string $id = null)
    {
        abort_if($id !== null && ! Str::isUuid($id), 404);
        $data = $request->validated(); // phone stored as E.164 when it is a mobile
        $data['is_active'] = $request->has('is_active') ? $request->boolean('is_active') : true;
        $sid = $this->repo()->saveSupplier($id, $data);
        ActivityLogger::log($id ? 'supplier.updated' : 'supplier.created', ($id ? 'Updated' : 'Added')." supplier {$data['name']}", null, ['supplier_id' => $sid]);

        return redirect()->route('suppliers.index')->with('status', "Supplier {$data['name']} saved.");
    }
}

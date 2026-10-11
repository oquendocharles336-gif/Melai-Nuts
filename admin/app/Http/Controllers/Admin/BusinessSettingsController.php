<?php

namespace App\Http\Controllers\Admin;

use App\Exceptions\BackendActionException;
use App\Http\Controllers\Controller;
use App\Services\ActivityLogger;
use App\Services\Supabase\SupabaseRepository;
use Illuminate\Http\Request;

/**
 * Owner-editable business settings (migration 20261018000000_business_settings.sql): restock
 * threshold fallback, stock-health and sales-rating ratios, daily sales targets, healthy margin,
 * and every branch's address / phone / hours / delivery fee. Stored ONLY in the shared database;
 * an empty field means "Not set" (nothing is filled in). The database checks that the caller is
 * the active owner; this controller only shapes the form.
 */
class BusinessSettingsController extends Controller
{
    /** form field => [database key, divide by] (ratios are typed as percentages). */
    private const FIELDS = [
        'restock_threshold_default' => ['restock_threshold_default', 1],
        'stock_low_percent' => ['stock_low_ratio', 100],
        'stock_plenty_percent' => ['stock_plenty_ratio', 100],
        'sales_low_percent' => ['sales_low_ratio', 100],
        'sales_high_percent' => ['sales_high_ratio', 100],
        'default_daily_sales_target' => ['default_daily_sales_target', 1],
        'healthy_margin_percent' => ['healthy_margin_percent', 1],
        'expiry_alert_days' => ['expiry_alert_days', 1],
    ];

    public function __construct(private SupabaseRepository $repo) {}

    public function index(Request $request)
    {
        abort_unless($request->user()->isAdmin(), 403);
        $settings = null;
        $error = null;
        try {
            $settings = $this->repo->businessSettings();
        } catch (BackendActionException|\App\Exceptions\BackendUnavailableException $e) {
            $error = $e->getMessage();
        }

        return view('admin.business.index', ['settings' => $settings, 'loadError' => $error, 'liveData' => true]);
    }

    public function update(Request $request)
    {
        abort_unless($request->user()->isAdmin(), 403);
        $data = $request->validate([
            'restock_threshold_default' => ['nullable', 'integer', 'min:0', 'max:100000'],
            'stock_low_percent' => ['nullable', 'numeric', 'gt:0', 'lt:100'],
            'stock_plenty_percent' => ['nullable', 'numeric', 'gt:0', 'max:100'],
            'sales_low_percent' => ['nullable', 'numeric', 'gt:0', 'max:1000'],
            'sales_high_percent' => ['nullable', 'numeric', 'gt:0', 'max:1000'],
            'default_daily_sales_target' => ['nullable', 'numeric', 'gt:0', 'max:100000000'],
            'healthy_margin_percent' => ['nullable', 'numeric', 'gt:0', 'lt:100'],
            'expiry_alert_days' => ['nullable', 'integer', 'min:1', 'max:365'],
        ]);
        if (isset($data['stock_low_percent'], $data['stock_plenty_percent']) && $data['stock_low_percent'] >= $data['stock_plenty_percent']) {
            return back()->withInput()->withErrors(['stock_low_percent' => '"Low" must be below "Plenty".']);
        }
        if (isset($data['sales_low_percent'], $data['sales_high_percent']) && $data['sales_low_percent'] > $data['sales_high_percent']) {
            return back()->withInput()->withErrors(['sales_low_percent' => '"Low below" cannot be above "High above".']);
        }

        $values = [];
        foreach (self::FIELDS as $field => [$key, $div]) {
            $v = $data[$field] ?? null;
            $values[$key] = $v === null || $v === '' ? null : round(((float) $v) / $div, 4);
        }
        foreach (['restock_threshold_default', 'expiry_alert_days'] as $int) {
            $values[$int] = $values[$int] === null ? null : (int) $values[$int];
        }

        try {
            $this->repo->updateBusinessSettings($values);
        } catch (BackendActionException $e) {
            return back()->withInput()->with('error', $e->getMessage());
        }
        ActivityLogger::log('business.settings_updated', 'Updated business settings in the app database', $request->user(), $values + ['source' => 'supabase']);

        return redirect()->route('admin.business.index')->with('status', 'Business settings saved. The app and this website use them right away.');
    }

    public function saveBranch(Request $request, ?string $branch = null)
    {
        abort_unless($request->user()->isAdmin(), 403);
        $d = $request->validate([
            'name' => ['required', 'string', 'max:80'],
            'address' => ['nullable', 'string', 'max:300'],
            'contact_phone' => ['nullable', 'string', 'max:40'],
            'operating_hours' => ['nullable', 'string', 'max:200'],
            'delivery_fee' => ['required', 'numeric', 'min:0', 'max:100000'],
            'daily_sales_target' => ['nullable', 'numeric', 'gt:0', 'max:100000000'],
        ], ['delivery_fee.required' => 'Enter the delivery fee (0 if delivery is free).']);
        $warehouse = $request->boolean('is_warehouse');
        // A warehouse only holds stock: it never takes deliveries, pickups or POS sales.
        $d['supports_delivery'] = ! $warehouse && $request->boolean('supports_delivery');
        $d['supports_pickup'] = ! $warehouse && $request->boolean('supports_pickup');
        $d['is_active'] = $request->boolean('is_active');
        $wasWarehouse = $branch !== null && (bool) (collect($this->repo->businessSettings()['branches'] ?? [])->firstWhere('id', $branch)['is_warehouse'] ?? false);

        try {
            if ($branch !== null && $wasWarehouse && ! $warehouse) {
                $this->repo->setBranchWarehouse($branch, false); // back to a shop first, then its options
            }
            $id = $this->repo->saveBranch($branch, $d);
            if ($warehouse && ! $wasWarehouse) {
                $this->repo->setBranchWarehouse($id, true);
            }
        } catch (BackendActionException $e) {
            return back()->withInput()->with('error', $e->getMessage());
        }
        ActivityLogger::log($branch ? 'branch.updated' : 'branch.created', ($branch ? 'Updated' : 'Added').' branch '.$d['name'], $request->user(),
            ['branch_id' => $id, 'source' => 'supabase']);

        return redirect()->route('admin.business.index')->with('status', ($branch ? 'Branch details saved: ' : 'Branch added: ').$d['name'].'.');
    }
}

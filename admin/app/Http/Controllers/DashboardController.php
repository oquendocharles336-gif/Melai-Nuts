<?php

namespace App\Http\Controllers;

use App\Services\DashboardService;
use App\Services\Platform;
use Illuminate\Http\Request;

class DashboardController extends Controller
{
    public function index(Request $request, DashboardService $dashboard)
    {
        $period = in_array($request->query('period'), ['today', 'week', 'month'], true) ? $request->query('period') : 'today';
        // Branch filter: "All branches" by default. Only branches this account may see are accepted
        // (DashboardService checks it against the list Supabase returns for the account).
        $branch = is_string($request->query('branch')) ? $request->query('branch') : null;

        return view('dashboard', $dashboard->build($period, $branch, $request->boolean('fresh')));
    }

    /**
     * Sidebar pages, all live from the app's database. (Only the automated tests, with their
     * fake data source, get the plain section page.)
     */
    public function section(string $slug, Platform $platform)
    {
        abort_unless(array_key_exists($slug, config('melai.sections')), 404);
        abort_if($slug === 'users' && ! auth()->user()->isAdmin(), 403);

        if ($platform->isSupabase()) {
            $live = ['sales' => [OperationsController::class, 'sales'], 'products' => [OperationsController::class, 'products'],
                'inventory' => [OperationsController::class, 'inventory'], 'cash-drawer' => [OperationsController::class, 'cashDrawer'],
                'reports' => [ReportsController::class, 'index']];
            if (isset($live[$slug])) {
                return app()->call([app($live[$slug][0]), $live[$slug][1]]);
            }
        }

        return view('section', ['title' => config('melai.sections')[$slug], 'slug' => $slug, 'liveData' => $platform->isSupabase()]);
    }
}

<?php

namespace App\Http\Controllers;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\StaffNotLinkedException;
use App\Models\ActivityLog;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;

class ActivityLogController extends Controller
{
    public function index(Platform $platform)
    {
        // Two trails: this website's own log (logins, user management, admin actions) and, with
        // Supabase, the app's append-only staff audit log (actions made in the app or through
        // this website's Supabase functions).
        $appLogs = null;
        $appLogsError = null;
        if ($platform->isSupabase()) {
            try {
                $appLogs = app(SupabaseRepository::class)->auditLogs(100);
            } catch (StaffNotLinkedException|BackendActionException|BackendUnavailableException $e) {
                $appLogsError = $e->getMessage();
            }
        }

        return view('admin.logs', [
            'logs' => ActivityLog::with('user')->latest('id')->paginate(25),
            'appLogs' => $appLogs, 'appLogsError' => $appLogsError, 'liveData' => $platform->isSupabase(),
        ]);
    }
}

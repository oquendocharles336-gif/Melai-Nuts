<?php

namespace App\Http\Controllers;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\StaffNotLinkedException;
use App\Models\ActivityLog;
use App\Services\ActivityLogger;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use App\Support\ListTools;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Http\Request;

class ActivityLogController extends Controller
{
    /** Website log, newest first, optionally filtered by ?q= (action, description, user, IP). */
    private function websiteLogs(string $q): Builder
    {
        $query = ActivityLog::with('user')->latest('id');
        foreach (array_filter(preg_split('/\s+/', $q)) as $word) {
            $like = '%'.str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $word).'%';
            $query->where(fn ($w) => $w->where('action', 'like', $like)->orWhere('description', 'like', $like)->orWhere('ip_address', 'like', $like)
                ->orWhereHas('user', fn ($u) => $u->where('name', 'like', $like)->orWhere('email', 'like', $like)));
        }

        return $query;
    }

    /** ?before= cursor for the app's audit log (an ISO time from the previous page). */
    private function before(Request $request): ?string
    {
        $b = $request->query('before');

        return is_string($b) && strtotime($b) !== false ? \Carbon\Carbon::parse($b)->toIso8601String() : null;
    }

    public function index(Request $request, Platform $platform)
    {
        // Two trails: this website's own log (logins, user management, admin actions) and, with
        // Supabase, the app's append-only staff audit log (actions made in the app or through
        // this website's Supabase functions).
        $q = ListTools::query($request);
        $appLogs = null;
        $appLogsError = null;
        $olderCursor = null;
        if ($platform->isSupabase()) {
            try {
                $page = app(SupabaseRepository::class)->auditLogs(100, $this->before($request));
                $olderCursor = count($page) === 100 ? end($page)['created_at'] : null;
                $appLogs = ListTools::search($page, $q, [self::class, 'appText']);
            } catch (StaffNotLinkedException|BackendActionException|BackendUnavailableException $e) {
                $appLogsError = $e->getMessage();
            }
        }

        return view('admin.logs', [
            'logs' => $this->websiteLogs($q)->paginate(ListTools::perPage($request))->appends(ListTools::linkQuery($request)),
            'q' => $q, 'olderCursor' => $olderCursor, 'before' => $this->before($request),
            'appLogs' => $appLogs, 'appLogsError' => $appLogsError, 'liveData' => $platform->isSupabase(),
        ]);
    }

    /** CSV: ?source=website (all matching rows, newest first, at most 10,000) or ?source=app (the shown page). */
    public function export(Request $request, Platform $platform)
    {
        $q = ListTools::query($request);
        ActivityLogger::log('logs.exported', 'Exported activity logs', $request->user(), ['q' => $q, 'source' => $request->query('source')]);
        $stamp = now('Asia/Manila')->format('Y-m-d');

        if ($request->query('source') === 'app') {
            abort_unless($platform->isSupabase(), 404);
            $rows = ListTools::search(app(SupabaseRepository::class)->auditLogs(100, $this->before($request)), $q, [self::class, 'appText']);

            return ListTools::csv("melai-app-audit-log-$stamp.csv", [
                'when' => fn ($l) => $l['created_at'], 'staff' => fn ($l) => $l['staff_name'] ?? $l['staff_email'] ?? null,
                'branch' => fn ($l) => $l['branch_name'] ?? null, 'action' => fn ($l) => $l['action'],
                'record' => fn ($l) => trim(($l['entity_type'] ?? '').' '.($l['entity_id'] ?? '')), 'details' => fn ($l) => $l['metadata'] ?? null,
            ], $rows);
        }

        return ListTools::csv("melai-website-activity-$stamp.csv", [
            'when' => fn ($l) => $l->created_at, 'user' => fn ($l) => $l->user?->name, 'email' => fn ($l) => $l->user?->email,
            'action' => fn ($l) => $l->action, 'details' => fn ($l) => $l->description, 'ip' => fn ($l) => $l->ip_address,
        ], $this->websiteLogs($q)->limit(10000)->get());
    }

    public static function appText(array $l): string
    {
        return implode(' ', [$l['action'] ?? '', $l['staff_name'] ?? '', $l['staff_email'] ?? '', $l['branch_name'] ?? '',
            $l['entity_type'] ?? '', $l['entity_id'] ?? '', json_encode($l['metadata'] ?? null, JSON_UNESCAPED_UNICODE)]);
    }
}

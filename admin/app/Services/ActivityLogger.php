<?php

namespace App\Services;

use App\Models\ActivityLog;
use App\Models\User;
use Illuminate\Support\Facades\Auth;

class ActivityLogger
{
    /** ActivityLogger::log('account.created', 'New account', $user, ['role' => 'staff']) */
    public static function log(string $action, ?string $description = null, ?User $user = null, array $meta = []): ActivityLog
    {
        $user ??= Auth::user();

        return ActivityLog::create([
            'user_id' => $user?->id,
            'action' => $action,
            'description' => $description,
            'meta' => $meta ?: null,
            'ip_address' => request()->ip(),
        ]);
    }
}

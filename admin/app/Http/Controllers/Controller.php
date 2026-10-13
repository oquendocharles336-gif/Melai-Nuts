<?php

namespace App\Http\Controllers;

use App\Services\OrderQueryService;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseRepository;

abstract class Controller
{
    // Per-request (scoped) services, resolved on each use instead of being held by the controller:
    // Laravel can reuse a controller instance across requests (test client, Octane), and a held one
    // would keep a previous request's account check and query results. Shared by every controller.

    protected function repo(): SupabaseRepository
    {
        return app(SupabaseRepository::class);
    }

    protected function orders(): OrderQueryService
    {
        return app(OrderQueryService::class);
    }

    protected function platform(): Platform
    {
        return app(Platform::class);
    }

    protected function identity(): StaffIdentity
    {
        return app(StaffIdentity::class);
    }
}

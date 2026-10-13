<?php

namespace App\Providers;

use App\Contracts\DataSource;
use App\Services\Data\SupabaseDataSource;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use App\Services\OrderQueryService;
use App\Services\Platform;
use App\Services\Supabase\SupabaseRepository;
use App\Services\Supabase\StaffIdentity;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Business data comes from the Melai Nuts app's Supabase database, always. There is no
        // other source in the website's code (the automated tests rebind this in admin/tests/).
        $this->app->scoped(DataSource::class, SupabaseDataSource::class);

        // One instance per request so the staff context and query results are fetched once.
        $this->app->scoped(StaffIdentity::class);
        $this->app->scoped(SupabaseRepository::class);
        $this->app->scoped(Platform::class);
        $this->app->scoped(OrderQueryService::class);
        $this->app->scoped(FirebaseSession::class);

        // Postgres connections get optional TCP keepalives (only 'supabase' sets keepalives_idle).
        $this->app->bind('db.connector.pgsql', \App\Database\PostgresKeepaliveConnector::class);
    }

    public function boot(): void
    {
        // One pager for every list (resources/views/pagination/melai.blade.php).
        \Illuminate\Pagination\Paginator::defaultView('pagination.melai');
        \Illuminate\Pagination\Paginator::defaultSimpleView('pagination.melai');
        // Money and payment-method labels: one definition for every page (App\Support\Format).
        \Illuminate\Support\Facades\View::share([
            'peso' => fn ($n) => \App\Support\Format::peso($n),
            'pesoWhole' => fn ($n) => \App\Support\Format::peso($n, 0),
            'methodLabel' => fn ($m) => \App\Support\Format::method($m),
        ]);

        // Firebase is how website logins prove who they are; say clearly at start-up what is missing.
        $firebase = $this->app->make(FirebaseConfig::class);
        if (! $this->app->environment('testing') && ! $firebase->ready()) {
            Log::warning('[melai] '.$firebase->missingMessage());
        }
    }
}

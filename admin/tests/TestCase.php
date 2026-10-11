<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Illuminate\Support\Facades\Http;
use App\Contracts\DataSource;
use App\Services\Data\SupabaseDataSource;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use Tests\Support\MockDataSource;
use Tests\Support\MockPlatform;

abstract class TestCase extends BaseTestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        // Feature tests render Blade layouts that call @vite; they must not need `npm run build` first.
        $this->withoutVite();
        // Tests never talk to the real Firebase / Google / HitPay: any request without a fake fails.
        Http::preventStrayRequests();
        // The website itself has ONE data source (Supabase). Tests run on fixtures from tests/Support by
        // default; a test switches to the real classes (with FakeSupabase or a real Postgres) by
        // setting the TEST-ONLY flag config('melai.data_source', 'supabase'). App code never reads it.
        config(['melai.data_source' => 'mock']);
        $fixtures = fn () => config('melai.data_source') !== 'supabase';
        $this->app->scoped(DataSource::class, fn ($app) => $fixtures() ? new MockDataSource : $app->make(SupabaseDataSource::class));
        $this->app->scoped(Platform::class, fn ($app) => $fixtures()
            ? new MockPlatform($app->make(StaffIdentity::class))
            : new Platform($app->make(StaffIdentity::class)));
    }
}

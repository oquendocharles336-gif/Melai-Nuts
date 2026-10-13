<?php

namespace Tests\Feature;

use App\Database\PostgresKeepaliveConnector;
use App\Models\User;
use App\Services\AdminActions;
use App\Services\Platform;
use App\Services\Supabase\StaffIdentity;
use App\Services\Supabase\SupabaseGateway;
use App\Support\Swr;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Request;
use Tests\TestCase;

/** Local speed settings: TCP keepalives, cache scoping per database, the opt-in account-check reuse. */
class LocalSpeedSettingsTest extends TestCase
{
    use RefreshDatabase;

    private function dsn(array $config): string
    {
        $m = new \ReflectionMethod(PostgresKeepaliveConnector::class, 'getDsn');

        return $m->invoke(new PostgresKeepaliveConnector, $config + ['host' => 'h', 'database' => 'd', 'port' => 5432, 'sslmode' => 'require']);
    }

    public function test_keepalives_are_added_only_when_configured(): void
    {
        $this->assertStringContainsString(';keepalives=1;keepalives_idle=30;keepalives_interval=10', $this->dsn(['keepalives_idle' => 30, 'keepalives_interval' => 10]));
        $this->assertStringNotContainsString('keepalives', $this->dsn(['keepalives_idle' => 0]));
        $this->assertStringNotContainsString('keepalives', $this->dsn([]));
        $this->assertInstanceOf(PostgresKeepaliveConnector::class, app('db.connector.pgsql'));
    }

    public function test_cached_answers_are_scoped_to_the_supabase_database(): void
    {
        config(['database.connections.supabase.url' => null, 'database.connections.supabase.host' => 'aws-0.pooler.supabase.com']);
        $remote = Swr::key('x');
        config(['database.connections.supabase.host' => '127.0.0.1']);
        $this->assertNotSame($remote, Swr::key('x'));
    }

    /** @return array{0: StaffIdentity, 1: object} identity with a gateway that counts its calls */
    private function identity(): array
    {
        $counter = new class { public int $calls = 0; };
        $gateway = \Mockery::mock(SupabaseGateway::class);
        $gateway->shouldReceive('call')->andReturnUsing(function () use ($counter) {
            $counter->calls++;

            return ['status' => 'active', 'profile' => ['role' => 'owner'], 'authorized_branches' => [['id' => 'b1', 'name' => 'B1']]];
        });
        $this->app->instance(SupabaseGateway::class, $gateway);
        $platform = \Mockery::mock(Platform::class);
        $platform->shouldReceive('isSupabase')->andReturn(true);
        $this->app->instance(Platform::class, $platform);

        return [fn () => new StaffIdentity($gateway), $counter];
    }

    public function test_account_is_checked_on_every_request_by_default(): void
    {
        config(['melai.account_check_seconds' => 0]);
        [$make, $counter] = $this->identity();
        $make()->contextFor('uid-1');
        $make()->contextFor('uid-1');   // a new request = a new scoped instance
        $this->assertSame(2, $counter->calls);
    }

    public function test_opt_in_reuses_an_active_check_for_page_loads_only(): void
    {
        config(['melai.account_check_seconds' => 15, 'cache.default' => 'array']);
        [$make, $counter] = $this->identity();

        $make()->contextFor('uid-1');
        $make()->contextFor('uid-1');
        $this->assertSame(1, $counter->calls, 'GET page loads reuse the recent check');

        $this->app->instance('request', Request::create('/orders', 'POST'));
        $make()->contextFor('uid-1');
        $this->assertSame(2, $counter->calls, 'changes always ask Supabase');

        $this->app->instance('request', Request::create('/dashboard', 'GET'));
        AdminActions::bump();
        $make()->contextFor('uid-1');
        $this->assertSame(3, $counter->calls, 'a change made on the website invalidates it');

        $id = $make();
        $id->forget('uid-1');
        $id->contextFor('uid-1');
        $this->assertSame(4, $counter->calls, 'forget() drops it');
    }

    public function test_doctor_runs_and_never_prints_secrets(): void
    {
        config(['database.connections.supabase.password' => 'super-secret-pw', 'database.connections.supabase.host' => '127.0.0.1', 'database.connections.supabase.port' => 1]);
        $this->artisan('melai:doctor', ['--pings' => 1])->doesntExpectOutputToContain('super-secret-pw')->assertSuccessful();
    }
}

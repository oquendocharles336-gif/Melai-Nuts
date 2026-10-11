<?php

namespace Tests\Perf;

use App\Services\Supabase\SupabaseGateway;
use App\Support\SupabaseTimer;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Support\PerfSupabase;
use Tests\Support\UsesFakeSupabase;
use Tests\TestCase;

/**
 * Supabase round trips per route (first visit and repeat visit), for an owner signed in through
 * Firebase. Prints a table (STDERR) and fails if a route goes over its budget.
 *
 *   php artisan test tests/Perf                       call counts only
 *   PERF_LATENCY_MS=120 php artisan test tests/Perf   + simulated 120 ms per Supabase round trip
 */
class RouteBudgetTest extends TestCase
{
    use RefreshDatabase, UsesFakeSupabase;

    /** Cold cache: account check + branch map positions + ONE batched read. Repeat: the account check only. */
    public const BUDGET = [
        '/dashboard' => [3, 1], '/dashboard/overview.json?range=30' => [3, 1], '/ui/counts.json' => [3, 1],
        '/orders' => [3, 1], '/s/reports' => [3, 1], '/s/inventory' => [3, 1],
    ];

    public function test_supabase_round_trips_per_route(): void
    {
        $this->useFakeSupabase();
        config(['melai.dashboard.cache_seconds' => 45, 'melai.timing' => true]);
        $db = PerfSupabase::build($this->db);
        $this->db = $db;
        $this->app->instance(SupabaseGateway::class, $db);
        $owner = $this->linkedLogin('uid-owner');

        $rows = [];
        foreach (self::BUDGET as $url => [$maxFirst, $maxRepeat]) {
            $out = [];
            \Illuminate\Support\Facades\Cache::flush(); // every route measured from a cold cache
            foreach (['first', 'repeat'] as $visit) {
                $t = microtime(true);
                $this->signedIn($owner)->get($url, ['Accept' => str_contains($url, '.json') ? 'application/json' : 'text/html'])->assertOk();
                $out[$visit] = ['ms' => (microtime(true) - $t) * 1000, 'calls' => SupabaseTimer::$calls,
                    'fns' => implode(' ', array_map(fn ($l) => $l['fn'], SupabaseTimer::$log))];
            }
            $rows[] = [$url, $out];
            $this->assertLessThanOrEqual($maxFirst, $out['first']['calls'], "$url first visit: ".$out['first']['fns']);
            $this->assertLessThanOrEqual($maxRepeat, $out['repeat']['calls'], "$url repeat visit: ".$out['repeat']['fns']);
        }

        // Instant shell (browser already ran our JS): no database call at all.
        foreach (['/dashboard', '/orders', '/s/inventory', '/s/reports'] as $url) {
            $t = microtime(true);
            $this->signedIn($owner)->withUnencryptedCookie('melai_js', '1')->get($url)->assertOk()->assertSee('data-shell', false);
            $ms = (microtime(true) - $t) * 1000;
            $this->assertSame(0, SupabaseTimer::$calls, "$url shell");
            $rows[] = ["$url (shell)", ['first' => ['calls' => 0, 'ms' => $ms, 'fns' => '(none)'], 'repeat' => ['calls' => 0, 'ms' => $ms, 'fns' => '']]];
        }

        $lat = (int) env('PERF_LATENCY_MS', 0);
        $txt = sprintf("\n  Supabase calls per route (simulated latency %d ms per call)\n  %-36s %16s %16s   %s\n", $lat, 'route', 'first: calls/ms', 'repeat: calls/ms', 'functions (first visit)');
        foreach ($rows as [$url, $o]) {
            $txt .= sprintf("  %-36s %8d %6.0fms %8d %6.0fms   %s\n", $url, $o['first']['calls'], $o['first']['ms'], $o['repeat']['calls'], $o['repeat']['ms'], $o['first']['fns']);
        }
        fwrite(STDERR, $txt);
        @file_put_contents(storage_path('logs/perf-table.txt'), $txt);
    }
}

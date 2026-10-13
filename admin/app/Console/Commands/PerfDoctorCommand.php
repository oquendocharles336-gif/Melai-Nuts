<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

/**
 * php artisan melai:doctor — why is the local website slow? Read-only: prints the active drivers,
 * measures the round trip to each database and checks the PHP / Laravel speed settings.
 * Never prints passwords, never changes anything.
 */
class PerfDoctorCommand extends Command
{
    protected $signature = 'melai:doctor {--pings=5 : round trips to time per database}';

    protected $description = 'Speed check: drivers, database round-trip times, OPcache/Xdebug, Laravel caches';

    private int $problems = 0;

    public function handle(): int
    {
        $this->components->info('Drivers');
        $default = config('database.default');
        $defaultHost = $this->hostOf($default);
        $this->line(sprintf('  DB_CONNECTION   %s %s', $default, $defaultHost ? "($defaultHost)" : ''));
        $this->check(! $this->isRemote($defaultHost), 'Laravel\'s own tables (users, sessions, cache) are on a REMOTE server: every page waits for 7+ queries over the internet. Use DB_CONNECTION=sqlite locally.');
        $session = config('session.driver');
        $this->line("  SESSION_DRIVER  $session".(config('session.encrypt') ? ' (encrypted: negligible cost)' : ''));
        $this->check(! in_array($session, ['database'], true) || ! $this->isRemote($this->hostOf(config('session.connection') ?? $default)), 'Sessions are stored in a REMOTE database (2-3 queries per page). Use SESSION_DRIVER=file.');
        $cache = config('cache.default');
        $this->line("  CACHE_STORE     $cache");
        $this->check(! in_array($cache, ['database'], true) || ! $this->isRemote($this->hostOf(config('cache.stores.database.connection') ?? $default)), 'The cache is stored in a REMOTE database. Use CACHE_STORE=file.');
        $this->line('  QUEUE           '.config('queue.default'));
        $supabaseHost = $this->hostOf('supabase');
        $this->line(sprintf('  Supabase data   %s (%s)', $supabaseHost ?: '-', $this->isRemote($supabaseHost) ? 'REMOTE project' : 'local copy'));
        $this->line('  Kept open       '.(config('database.connections.supabase.options')[\PDO::ATTR_PERSISTENT] ? 'yes (SUPABASE_DB_PERSISTENT=true)' : 'NO'));
        $this->check((bool) config('database.connections.supabase.options')[\PDO::ATTR_PERSISTENT] || ! $this->isRemote($supabaseHost), 'SUPABASE_DB_PERSISTENT=false: every page opens a new SSL connection to Supabase (~4 extra round trips).');

        $this->components->info('Database round trips (select 1)');
        foreach (array_unique([$default, 'supabase']) as $name) {
            $this->ping($name);
        }

        $this->components->info('PHP');
        $this->line('  PHP '.PHP_VERSION.' on '.PHP_OS_FAMILY);
        $this->check(version_compare(PHP_VERSION, '8.3.0', '>='), 'PHP '.PHP_VERSION.': PHP 8.3+ is faster.');
        $opcache = extension_loaded('Zend OPcache') && filter_var(ini_get('opcache.enable'), FILTER_VALIDATE_BOOL);
        $this->line('  OPcache         '.($opcache ? 'on (memory '.ini_get('opcache.memory_consumption').' MB, revalidate_freq '.ini_get('opcache.revalidate_freq').')' : 'OFF'));
        $this->check($opcache, 'OPcache is off: in php.ini set zend_extension=opcache and opcache.enable=1 (php --ini shows the file).');
        $this->line('  realpath cache  '.ini_get('realpath_cache_size'));
        $this->check($this->bytes(ini_get('realpath_cache_size')) >= 1024 * 1024, 'realpath_cache_size is small: set realpath_cache_size=4096K in php.ini.');
        $this->check(! extension_loaded('xdebug'), 'Xdebug is loaded: it slows every request 2-5x. Comment out zend_extension=xdebug in php.ini.');
        if (extension_loaded('xdebug')) {
            $this->line('  Xdebug          LOADED');
        }

        $this->components->info('Laravel');
        $this->line('  APP_ENV/DEBUG   '.app()->environment().' / '.(config('app.debug') ? 'true' : 'false'));
        $this->check(! config('app.debug'), 'APP_DEBUG=true adds overhead; set false unless you are fixing an error.');
        foreach (['config' => app()->configurationIsCached(), 'routes' => app()->routesAreCached(), 'events' => app()->eventsAreCached()] as $what => $ok) {
            $this->line(sprintf('  %-15s %s', "$what cached", $ok ? 'yes' : 'no (php artisan optimize)'));
        }
        $classmap = base_path('vendor/composer/autoload_classmap.php');
        $optimized = is_file($classmap) && count(require $classmap) > 1000;
        $this->line('  autoloader      '.($optimized ? 'optimized' : 'NOT optimized (composer dump-autoload -o)'));
        $hot = is_file(public_path('hot'));
        $this->line('  page assets     '.($hot ? 'Vite DEV server (public/hot exists)' : (is_file(public_path('build/manifest.json')) ? 'built (npm run build)' : 'MISSING: run npm run build')));
        $this->check(! $hot, 'public/hot exists: pages load scripts from the Vite dev server. Stop `npm run dev` and delete public/hot unless you are editing CSS/JS.');
        $this->line('  timing logs     '.(config('melai.timing') ? 'MELAI_TIMING on (turn off when done)' : 'off'));
        $this->line('  account check   '.((int) config('melai.account_check_seconds') > 0 ? 'reused for '.config('melai.account_check_seconds').' s (MELAI_ACCOUNT_CHECK_SECONDS)' : 'every request'));

        if (PHP_OS_FAMILY === 'Windows') {
            $this->components->info('Windows');
            $this->check(! str_contains(strtolower(base_path()), 'onedrive'), 'The project is inside OneDrive: move it to e.g. C:\\dev\\Melai-Nuts (sync locks and scans files).');
            $this->line('  Workers         php artisan serve answers ONE request at a time on Windows (PHP_CLI_SERVER_WORKERS is not supported). Use Laragon or Herd for parallel requests.');
            $this->line('  Defender        check exclusions (admin PowerShell): Get-MpPreference | Select -Expand ExclusionPath');
            $this->line('                  add: Add-MpPreference -ExclusionPath "'.dirname(base_path()).'"');
        }

        $this->newLine();
        $this->problems ? $this->components->warn("{$this->problems} thing(s) to fix above.") : $this->components->info('No problems found.');

        return self::SUCCESS;
    }

    private function ping(string $name): void
    {
        try {
            $db = DB::connection($name);
            $t = microtime(true);
            $db->getPdo();
            $connect = (microtime(true) - $t) * 1000;
            $times = [];
            for ($i = 0; $i < max(1, (int) $this->option('pings')); $i++) {
                $t = microtime(true);
                $db->select('select 1');
                $times[] = (microtime(true) - $t) * 1000;
            }
            sort($times);
            $median = $times[intdiv(count($times), 2)];
            $this->line(sprintf('  %-10s connect %4.0f ms · query median %5.1f ms (min %.1f, max %.1f)', $name, $connect, $median, min($times), max($times)));
            $this->check($median < 20 || $name === 'supabase', "Each query on '$name' costs {$median} ms: that connection should be local.");
        } catch (\Throwable $e) {
            $this->line("  $name: cannot connect (".class_basename($e).')');
        }
    }

    private function hostOf(?string $connection): string
    {
        $c = config("database.connections.$connection", []);
        if (($c['driver'] ?? null) === 'sqlite') {
            return '';
        }
        if (! empty($c['url'])) {
            return (string) parse_url($c['url'], PHP_URL_HOST);
        }

        return (string) ($c['host'] ?? '');
    }

    private function isRemote(string $host): bool
    {
        return $host !== '' && ! in_array(strtolower($host), ['127.0.0.1', 'localhost', '::1'], true);
    }

    private function check(bool $ok, string $problem): void
    {
        if (! $ok) {
            $this->problems++;
            $this->line("  <fg=yellow>!</> $problem");
        }
    }

    private function bytes(string $v): int
    {
        $n = (int) $v;

        return match (strtoupper(substr(trim($v), -1))) { 'G' => $n << 30, 'M' => $n << 20, 'K' => $n << 10, default => $n };
    }
}

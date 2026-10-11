<?php

namespace App\Services\Supabase;

use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Support\SupabaseTimer;
use Closure;
use Illuminate\Database\ConnectionInterface;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use PDO;
use PDOException;

/**
 * The only way this app talks to the mobile app's Supabase database.
 *
 * Every call runs inside one transaction that first does exactly what Supabase's own API
 * (PostgREST) does for a signed-in app user:
 *     set_config('request.jwt.claims', {"sub": <firebase uid>, "role": "authenticated"}, true)
 *     SET LOCAL ROLE authenticated
 * so Row Level Security and the staff/owner checks inside every SQL function apply to the
 * admin portal exactly as they apply to the Flutter app. The Laravel database login
 * (`melai_admin_portal`) has no privileges of its own.
 *
 * The UID always comes from StaffIdentity (the signed-in Laravel user's linked staff account),
 * never from a request parameter.
 */
class SupabaseGateway
{
    public function connection(): ConnectionInterface
    {
        $db = DB::connection(config('melai.supabase.connection', 'supabase'));
        // call() sends two statements in one message; only emulated prepares allow that (Postgres
        // refuses several commands in one server-side prepared statement). Values are still bound
        // and escaped by PDO. Also set in config/database.php so a reconnect keeps it.
        // (Timing only: the first use per request opens / re-uses the persistent connection.)
        $pdo = SupabaseTimer::$connected ? $db->getPdo() : SupabaseTimer::connect(fn () => $db->getPdo());
        $pdo->setAttribute(PDO::ATTR_EMULATE_PREPARES, true);

        return $db;
    }

    /**
     * Run $work as the given staff member. All statements share one transaction, so a
     * multi-step action either fully happens or not at all.
     *
     * @template T
     * $verified may carry the 'email' / 'email_verified' of the VERIFIED Firebase ID token of
     * that same UID (never request input); SQL functions that read the caller's own email from
     * the JWT (auth.jwt() ->> 'email') then see what the Flutter app's token would carry.
     *
     * @param  Closure(ConnectionInterface): T  $work
     * @return T
     */
    public function actingAs(string $firebaseUid, Closure $work, array $verified = []): mixed
    {
        $claims = $this->claims($firebaseUid, $verified);

        try {
            return SupabaseTimer::measure('actingAs', fn () => $this->connection()->transaction(function (ConnectionInterface $db) use ($claims, $work) {
                // set_config('role', ..., true) is exactly SET LOCAL ROLE (it is what PostgREST runs);
                // both settings in one statement = one round trip to the database instead of two.
                $db->select(self::AS_APP_USER, [$claims]);

                return $work($db);
            }));
        } catch (QueryException $e) {
            throw $this->translate($e);
        } catch (PDOException $e) {
            throw $this->unreachable($e);
        }
    }

    /**
     * Call one SQL function that returns json/jsonb (or nothing) and decode the result.
     *
     * SPEED: the database is far away (every round trip costs ~0.1 s or more), so this sends
     *     select set_config(<claims>), set_config('role', 'authenticated');  <the function call>
     * as ONE message: one round trip instead of about ten (BEGIN, claims, role, query, COMMIT, each
     * prepared statement also costing a prepare and a DEALLOCATE).
     * Postgres runs the statements of one message as ONE implicit transaction, so the
     * transaction-local claims and role apply to the function call and are dropped right after
     * it, and an error rolls everything back: the same guarantees as actingAs().
     * (Needs emulated prepares, see connection(); inside an already open transaction the
     * regular actingAs() path is used.)
     */
    public function call(string $firebaseUid, string $sql, array $bindings = [], array $verified = []): mixed
    {
        $claims = $this->claims($firebaseUid, $verified);

        try {
            $db = $this->connection();
            if ($db->transactionLevel() > 0) {
                return $this->actingAs($firebaseUid, fn (ConnectionInterface $db) => $this->decode($db->selectOne($sql, $bindings)), $verified);
            }

            return SupabaseTimer::measure(SupabaseTimer::label($sql), fn () => $this->decode($db->selectOne(self::AS_APP_USER.";\n".$sql, [$claims, ...$bindings])));
        } catch (QueryException $e) {
            throw $this->translate($e);
        } catch (PDOException $e) {
            throw $this->unreachable($e);
        }
    }

    /** Sets the signed-in app user for the current transaction (request.jwt.claims + role). */
    private const AS_APP_USER = "select set_config('request.jwt.claims', ?, true), set_config('role', 'authenticated', true)";

    private function claims(string $firebaseUid, array $verified): string
    {
        if ($firebaseUid === '' || strlen($firebaseUid) > 128) {
            throw new BackendActionException('Your admin account is not linked to a valid staff account.');
        }
        $extra = array_intersect_key($verified, ['email' => true, 'email_verified' => true]);

        return json_encode(['sub' => $firebaseUid, 'role' => 'authenticated'] + $extra, JSON_THROW_ON_ERROR);
    }

    private function decode(?object $row): mixed
    {
        $value = $row ? (array) $row : [];
        $value = reset($value);

        // Functions that return void come back as '' when cast to text.
        if ($value === null || $value === false || $value === '') {
            return null;
        }

        return is_string($value) ? json_decode($value, true, 512, JSON_THROW_ON_ERROR) : $value;
    }

    private function unreachable(PDOException $e): BackendUnavailableException
    {
        Log::error('[supabase] connection failed: '.$e->getMessage());

        return new BackendUnavailableException('The Melai Nuts database could not be reached. Please try again in a moment.', 0, $e);
    }

    /**
     * The ONE call that does not act as an app user: which staff_members UID has this e-mail and
     * role? (portal_staff_uid_for_email, executable only by the website's own database login.)
     * It returns a UID and nothing else; AutoLinker then verifies that UID with
     * get_my_staff_context() AS that UID (actingAs) before anything is linked or read.
     *
     * @return array{status: string, firebase_uid?: string, account_status?: string, count?: int}
     */
    public function staffUidForEmail(string $email, string $role): array
    {
        try {
            $row = SupabaseTimer::measure('portal_staff_uid_for_email', fn () => $this->connection()->selectOne('select public.portal_staff_uid_for_email(?::text, ?::text)::text as r', [$email, $role]));
        } catch (QueryException $e) {
            throw $this->translate($e);
        } catch (PDOException $e) {
            throw $this->unreachable($e);
        }

        return json_decode((string) ($row->r ?? '{}'), true) ?: ['status' => 'none'];
    }

    /** True when $e comes from a SQL function that does not exist yet (a migration was not run). */
    public static function isMissingFunction(\Throwable $e): bool
    {
        $q = $e instanceof QueryException ? $e : $e->getPrevious();

        return $q instanceof QueryException && ($q->errorInfo[0] ?? null) === '42883';
    }

    /** Turn a database error into something safe to show, keeping the details in the log. */
    private function translate(QueryException $e): \RuntimeException
    {
        $state = $e->errorInfo[0] ?? $e->getCode();
        $raw = (string) ($e->errorInfo[2] ?? $e->getMessage());

        // P0001 = RAISE EXCEPTION inside our SQL functions: written for humans, show it.
        // 28000 = not authenticated (no/blank UID).
        if (in_array($state, ['P0001', '28000'], true)) {
            $message = preg_match('/ERROR:\s+(.+?)(\n|$)/', $raw, $m) ? trim($m[1]) : 'The request was refused.';

            return new BackendActionException($message, 0, $e);
        }

        // 42501 = insufficient privilege: RLS / grants refused it.
        if ($state === '42501') {
            return new BackendActionException('You do not have permission to do that.', 0, $e);
        }

        Log::error('[supabase] query failed', ['sqlstate' => $state, 'error' => $raw,
            'hint' => $state === '42883' ? 'A function is missing: run every file in supabase/migrations (latest: 20261013000000_admin_portal_owner_overview.sql).' : null]);

        // 08xxx = connection problems.
        if (is_string($state) && str_starts_with($state, '08')) {
            return new BackendUnavailableException('The Melai Nuts database could not be reached. Please try again in a moment.', 0, $e);
        }

        return new BackendUnavailableException('The Melai Nuts database returned an unexpected error. The details were logged for the administrator.', 0, $e);
    }
}

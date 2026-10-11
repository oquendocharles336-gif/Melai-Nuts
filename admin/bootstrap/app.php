<?php

use App\Exceptions\AccountLinkException;
use App\Exceptions\BackendActionException;
use App\Exceptions\BackendUnavailableException;
use App\Exceptions\StaffNotLinkedException;
use App\Http\Middleware\EnsureHasAccess;
use App\Http\Middleware\EnsureRole;
use App\Http\Middleware\EnsureSupabase;
use App\Http\Middleware\EnsureUserIsActive;
use App\Http\Middleware\ResetRequestScope;
use App\Services\ActivityLogger;
use App\Services\Auth\LinkState;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware) {
        $middleware->prepend(ResetRequestScope::class);
        $middleware->append(\App\Http\Middleware\SecurityHeaders::class); // CSP, nosniff, frame, HSTS (config/melai.php)
        // Set by resources/js/ui.js (plain "1", no secret): lets heavy pages answer with an instant shell.
        $middleware->encryptCookies(except: ['melai_js']);
        $middleware->prepend(\App\Http\Middleware\ServerTiming::class); // TEMPORARY: MELAI_TIMING=true
        $middleware->alias([
            'role'       => EnsureRole::class,         // role:admin -> 403 if not allowed
            'has.access' => EnsureHasAccess::class,    // no access yet -> "Waiting" page
            'active'     => EnsureUserIsActive::class, // deactivated -> logged out
            'supabase'   => EnsureSupabase::class,     // shared-database pages; 404 for the tests' fake data source
            'shell'      => \App\Http\Middleware\ShellFirst::class, // heavy pages: instant shell, content fetched by the browser
            'bumps.cache' => \App\Http\Middleware\BumpCacheVersion::class, // any successful change invalidates cached data
        ]);
        $middleware->redirectGuestsTo(fn () => route('login'));    // guests -> login
        $middleware->redirectUsersTo(fn () => route('dashboard')); // logged-in -> dashboard
    })
    ->withExceptions(function (Exceptions $exceptions) {
        // Shared-database (Supabase) problems are shown as clear messages, never as a stack trace.
        $show = function (string $title, string $message, int $status, Request $request) {
            if ($request->expectsJson()) {
                return response()->json(['message' => $message], $status);
            }
            if (! $request->isMethod('GET')) {
                return back()->withInput($request->except(['password', 'password_confirmation']))->with('error', $message);
            }

            return response()->view('errors.backend', ['title' => $title, 'message' => $message], $status);
        };
        // The login cannot act as its app account right now: no verified Firebase sign-in (expired and
        // not refreshable, revoked, forged, local-password session), not linked, deactivated in the app...
        // JSON gets 401. Pages sign the person out and send them to the LOGIN page with the reason;
        // signing in again links the account automatically. Nothing is read or written.
        $signInAgain = function (\RuntimeException $e, Request $r) {
            $state = $e instanceof AccountLinkException ? $e->state : LinkState::NOT_AUTHENTICATED;
            if ($r->expectsJson()) {
                return response()->json(['message' => $e->getMessage(), 'state' => $state], 401);
            }
            if ($user = $r->user()) {
                ActivityLogger::log('auth.session_ended', 'Signed out: '.$e->getMessage(), $user, ['state' => $state]);
            }
            Auth::guard('web')->logout();
            $r->session()->invalidate();
            $r->session()->regenerateToken();
            if ($r->isMethod('GET')) {
                $r->session()->put('url.intended', $r->fullUrl());
            }

            return redirect()->route('login')->withInput(['email' => $user?->email])->withErrors(['auth' => $e->getMessage()]);
        };
        $exceptions->render(fn (StaffNotLinkedException $e, Request $r) => $signInAgain($e, $r));
        $exceptions->render(fn (AccountLinkException $e, Request $r) => $signInAgain($e, $r)); // incl. FirebaseSessionRequiredException
        $exceptions->render(fn (BackendActionException $e, Request $r) => $show('Not allowed', $e->getMessage(), 403, $r));
        $exceptions->render(fn (BackendUnavailableException $e, Request $r) => $show('Database unavailable', $e->getMessage(), 503, $r));
    })
    ->create();

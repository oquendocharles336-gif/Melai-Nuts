<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Http\Requests\Rules;
use App\Models\User;
use App\Services\ActivityLogger;
use App\Services\Auth\AccountEmailException;
use App\Services\Auth\AccountEmails;
use App\Support\AuthPanel;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

/**
 * The landing page of the links in our account e-mails (Supabase function account-email), for app
 * AND website accounts (it is one Firebase account). The app opens the same URL (Android App Link).
 *
 *   mode=resetPassword&token=…      the link is checked first (not used up), then the new password
 *                                   is set with the same rules as the app; the link works once and
 *                                   the account's other sign-ins end.
 *   mode=confirmEmail&token=…       from the NEW address: the e-mail change is applied.
 *   mode=cancelEmailChange&token=…  from the OLD address: the pending change is stopped.
 *
 * The token is only in the URL / form: never stored here or logged, and the page sends no Referer.
 * Old Firebase links (oobCode=…) are answered with "ask for a new link".
 */
class AccountActionController extends Controller
{
    public function __construct(private AccountEmails $emails) {}

    public function show(Request $request)
    {
        $mode = (string) $request->query('mode', '');
        $token = (string) $request->query('token', '');
        $isReset = $mode === 'resetPassword';
        if ($token === '' || strlen($token) > 200) {
            return $this->page('invalid', ['message' => $request->query('oobCode')
                ? 'This link is from an older email and no longer works. Ask for a new one.'
                : 'This link is not complete. Open the link from the most recent Melai Nuts email.', 'reset' => $isReset]);
        }

        try {
            return match ($mode) {
                'resetPassword' => $this->page('reset', ['token' => $token] + $this->emails->checkPasswordReset($token)),
                // Both are single, harmless actions; a confirm button keeps link scanners from using them up.
                'confirmEmail' => $this->page('confirm-email', ['token' => $token]),
                'cancelEmailChange' => $this->page('cancel-email', ['token' => $token]),
                default => $this->page('invalid', ['message' => 'This link is not one of ours. Open the link from the most recent Melai Nuts email.']),
            };
        } catch (AccountEmailException $e) {
            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => $isReset]);
        }
    }

    public function reset(Request $request)
    {
        $token = (string) $request->input('token', '');
        if ($token === '' || strlen($token) > 200) {
            return $this->page('invalid', ['message' => 'This link is not complete. Open the link from the most recent Melai Nuts email.', 'reset' => true]);
        }
        try {
            // Checked again here: the e-mail comes from the link, never from the form.
            $email = $this->emails->checkPasswordReset($token)['email'];
        } catch (AccountEmailException $e) {
            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => true]);
        }

        $request->validate(['password' => array_merge(Rules::newPassword($email, null), ['confirmed'])], Rules::messages());

        try {
            $email = $this->emails->confirmPasswordReset($token, (string) $request->input('password')) ?: $email;
        } catch (AccountEmailException $e) {
            if ($e->reason === 'weak_password') {
                throw ValidationException::withMessages(['password' => $e->getMessage()]);
            }

            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => true]);
        }
        $this->endWebsiteSessions($email);
        ActivityLogger::log('auth.password_reset', 'Password reset through the e-mailed link', null, ['email' => $email]);

        return $this->page('done', ['email' => $email, 'signIn' => AuthPanel::url(AuthPanel::SIGN_IN)]);
    }

    public function confirmEmail(Request $request)
    {
        try {
            $new = $this->emails->confirmEmailChange((string) $request->input('token', ''));
        } catch (AccountEmailException $e) {
            return $this->page('invalid', ['message' => $e->getMessage()]);
        }
        ActivityLogger::log('auth.email_changed', 'Email address changed through the e-mailed link', null, ['email' => $new]);

        return $this->page('applied', ['title' => 'Email changed', 'message' => "Your Melai Nuts account now uses {$new}. Sign in again with this address in the app and on this website.",
            'signIn' => AuthPanel::url(AuthPanel::SIGN_IN)]);
    }

    public function cancelEmail(Request $request)
    {
        try {
            $this->emails->cancelEmailChange((string) $request->input('token', ''));
        } catch (AccountEmailException $e) {
            return $this->page('invalid', ['message' => $e->getMessage()]);
        }
        ActivityLogger::log('auth.email_change_cancelled', 'Pending email change stopped from the old address', null);

        return $this->page('applied', ['title' => 'Change stopped', 'message' => 'The email change was stopped; your account keeps its current email. If you did not ask for it, change your password now.',
            'signIn' => AuthPanel::url(AuthPanel::RESET_PASSWORD), 'signInLabel' => 'Change my password']);
    }

    /** The website's own sessions of that account end at once (Firebase ends the app's). */
    private function endWebsiteSessions(string $email): void
    {
        if (config('session.driver') !== 'database' || $email === '') {
            return;
        }
        $ids = User::where('email', mb_strtolower($email))->pluck('id');
        if ($ids->isNotEmpty()) {
            DB::connection(config('session.connection'))->table(config('session.table', 'sessions'))->whereIn('user_id', $ids)->delete();
        }
    }

    private function page(string $state, array $data)
    {
        return response()->view('auth.account-action', ['state' => $state] + $data + [
            'forgot' => AuthPanel::url(AuthPanel::RESET_PASSWORD),
        ])->header('Referrer-Policy', 'no-referrer')->header('Cache-Control', 'no-store');
    }
}

<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Http\Requests\Rules;
use App\Services\ActivityLogger;
use App\Services\Firebase\FirebaseAuthClient;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Support\AuthPanel;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;

/**
 * The landing page of the links in Firebase's account e-mails, for app AND website accounts
 * (it is one Firebase account). Firebase console > Authentication > Templates > (each template) >
 * Customize action URL = https://<this website>/auth/action. See docs/PASSWORD_RESET.md.
 *
 *   mode=resetPassword  the code is checked first (not used up), then the new password is set
 *                       with the same rules as the app; Firebase accepts the code once, so the
 *                       link stops working, and the account's other sign-ins end.
 *   mode=verifyEmail / recoverEmail   applied by Firebase, the result is shown.
 *
 * The code is only in the URL / form: never stored or logged, and the page sends no Referer.
 */
class AccountActionController extends Controller
{
    public function __construct(private FirebaseAuthClient $firebase, private FirebaseConfig $config) {}

    public function show(Request $request)
    {
        $mode = (string) $request->query('mode', '');
        $code = (string) $request->query('oobCode', '');
        if (! $this->config->ready()) {
            return $this->page('invalid', ['message' => $this->config->missingMessage()]);
        }
        if ($code === '' || strlen($code) > 512) {
            return $this->page('invalid', ['message' => 'This link is not complete. Open the link from the most recent Melai Nuts e-mail.']);
        }

        try {
            return match ($mode) {
                'resetPassword' => $this->page('reset', ['code' => $code, 'email' => $this->firebase->verifyPasswordResetCode($code)]),
                'verifyEmail', 'recoverEmail' => $this->applied($mode, $code),
                default => $this->page('invalid', ['message' => 'This link is not one of ours. Open the link from the most recent Melai Nuts e-mail.']),
            };
        } catch (FirebaseAuthException $e) {
            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => $mode === 'resetPassword']);
        }
    }

    public function reset(Request $request)
    {
        $code = (string) $request->input('oobCode', '');
        if ($code === '' || strlen($code) > 512) {
            return $this->page('invalid', ['message' => 'This link is not complete. Open the link from the most recent Melai Nuts e-mail.', 'reset' => true]);
        }
        try {
            // Checked again here: the e-mail comes from Firebase, never from the form.
            $email = $this->firebase->verifyPasswordResetCode($code);
        } catch (FirebaseAuthException $e) {
            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => true]);
        }

        $request->validate(['password' => array_merge(Rules::newPassword($email, null), ['confirmed'])], Rules::messages());

        try {
            $this->firebase->confirmPasswordReset($code, (string) $request->input('password'));
        } catch (FirebaseAuthException $e) {
            if ($e->reason === FirebaseAuthException::WEAK_PASSWORD) {
                throw ValidationException::withMessages(['password' => $e->getMessage()]);
            }

            return $this->page('invalid', ['message' => $e->getMessage(), 'reset' => true]);
        }
        ActivityLogger::log('auth.password_reset', 'Password reset through the e-mailed link', null, ['email' => $email]);

        return $this->page('done', ['email' => $email, 'signIn' => AuthPanel::url(AuthPanel::SIGN_IN)]);
    }

    private function applied(string $mode, string $code)
    {
        $this->firebase->applyActionCode($code);

        return $this->page('applied', ['message' => $mode === 'verifyEmail'
            ? 'Your e-mail address is verified. You can sign in now.'
            : 'Your e-mail address was changed back. If you did not ask for the change, reset your password now.',
            'signIn' => AuthPanel::url(AuthPanel::SIGN_IN)]);
    }

    private function page(string $state, array $data)
    {
        return response()->view('auth.account-action', ['state' => $state] + $data + [
            'forgot' => AuthPanel::url(AuthPanel::RESET_PASSWORD),
        ])->header('Referrer-Policy', 'no-referrer')->header('Cache-Control', 'no-store');
    }
}

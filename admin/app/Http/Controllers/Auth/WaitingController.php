<?php

namespace App\Http\Controllers\Auth;

use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Http\Controllers\Controller;
use App\Services\Auth\AccountLinkStatus;
use App\Services\Auth\EmailCodeException;
use App\Services\Auth\EmailCodes;
use App\Services\Auth\LinkState;
use App\Services\Firebase\FirebaseAuthException;
use App\Services\Firebase\FirebaseConfig;
use App\Services\Firebase\FirebaseSession;
use Illuminate\Http\Request;

/**
 * "Waiting for access": shown to an owner login whose app link is not verified yet.
 * The website has no sign-up and no staff access (staff use the Melai Nuts app only), so there is
 * no registration here any more.
 */
class WaitingController extends Controller
{
    /** "Waiting for access": re-reads the Firebase account (email verified?) and the app registration. */
    public function waiting(Request $request, FirebaseConfig $config, FirebaseSession $session, AccountLinkStatus $status)
    {
        $user = $request->user();
        if ($user->has_access) {
            return redirect()->route('dashboard');
        }

        $state = null;
        if ($user->usesFirebase() && $config->ready()) {
            try {
                $claims = $session->claimsFor($user, forceRefresh: true);
                if ($user->firebase_email_verified !== $claims['email_verified']) {
                    $user->forceFill(['firebase_email_verified' => $claims['email_verified']])->save();
                }
                $state = $status->evaluate($user, $claims, link: true);
                if ($user->fresh()->has_access) {
                    return redirect()->route('dashboard')->with('status', 'Your account is linked. Welcome!');
                }
            } catch (FirebaseSessionRequiredException $e) {
                $state = ['state' => $e->state, 'message' => $e->getMessage()];
            } catch (BackendUnavailableException $e) {
                $state = ['state' => LinkState::TEMPORARY_ERROR, 'message' => $e->getMessage()];
            }
        }

        return view('auth.waiting', ['user' => $user->fresh(), 'state' => $state]);
    }

    /** Emails a 6-digit code (Melai Nuts' own e-mail; Firebase's link is not used). Needs the security check. */
    public function resendVerification(Request $request, FirebaseConfig $config, FirebaseSession $session, EmailCodes $codes)
    {
        $user = $request->user();
        abort_unless($user->usesFirebase() && $config->ready(), 404);
        try {
            $codes->send($session->idTokenFor($user), $this->captchaToken($request));
        } catch (FirebaseSessionRequiredException|FirebaseAuthException|EmailCodeException $e) {
            return back()->with('error', $e->getMessage());
        }
        session()->put('waiting_code_sent', true);

        return back()->with('status', "We emailed a 6-digit code to {$user->email}.");
    }

    /** Checks the code (the server checks the security check first), then re-reads the account. */
    public function verifyCode(Request $request, FirebaseConfig $config, FirebaseSession $session, EmailCodes $codes)
    {
        $user = $request->user();
        abort_unless($user->usesFirebase() && $config->ready(), 404);
        $data = $request->validate(['code' => ['required', 'string', 'regex:/^\s*\d{3}\s?\d{3}\s*$/']],
            ['code.required' => 'Enter the 6-digit code from the email.', 'code.regex' => 'The code must be exactly 6 digits.']);
        try {
            $codes->verify($session->idTokenFor($user), preg_replace('/\D/', '', $data['code']), $this->captchaToken($request));
        } catch (FirebaseSessionRequiredException|FirebaseAuthException|EmailCodeException $e) {
            return back()->with('error', $e->getMessage());
        }
        session()->forget('waiting_code_sent');

        // "Check again" re-reads the account with a fresh token (email_verified is now true).
        return redirect()->route('waiting')->with('status', 'Your email is verified.');
    }

    private function captchaToken(Request $request): ?string
    {
        $t = $request->input('cf-turnstile-response');

        return is_string($t) && $t !== '' && strlen($t) <= 2048 ? $t : null;
    }
}

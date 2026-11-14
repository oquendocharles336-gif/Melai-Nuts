<?php

namespace App\Http\Controllers\Auth;

use App\Exceptions\BackendUnavailableException;
use App\Exceptions\FirebaseSessionRequiredException;
use App\Http\Controllers\Controller;
use App\Services\Auth\AccountLinkStatus;
use App\Services\Auth\LinkState;
use App\Services\Firebase\FirebaseAuthClient;
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

    public function resendVerification(Request $request, FirebaseConfig $config, FirebaseSession $session, FirebaseAuthClient $client)
    {
        $user = $request->user();
        abort_unless($user->usesFirebase() && $config->ready(), 404);
        try {
            $client->sendEmailVerification($session->idTokenFor($user));
        } catch (FirebaseSessionRequiredException|FirebaseAuthException $e) {
            return back()->with('error', $e->getMessage());
        }

        return back()->with('status', "Verification link sent to {$user->email}.");
    }
}

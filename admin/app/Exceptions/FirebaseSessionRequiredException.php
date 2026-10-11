<?php

namespace App\Exceptions;

/**
 * A page needs the signed-in user's Firebase identity (to act as their app account in Supabase),
 * but the session has none, or its ID token is invalid / expired and could not be refreshed.
 * The token is refreshed silently first (FirebaseSession); only when that fails is this thrown.
 * Rendered as 401 (JSON) or a sign-out + redirect to the login page with the reason (bootstrap/app.php).
 */
class FirebaseSessionRequiredException extends AccountLinkException {}

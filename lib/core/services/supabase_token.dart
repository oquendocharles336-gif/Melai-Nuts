import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/supabase_config.dart';

/// Supplies the Firebase ID token that Supabase uses to pick a Postgres role.
///
/// Supabase maps the token's `role` claim to a Postgres role. Firebase tokens
/// carry no such claim by default, and without `role: authenticated` every
/// request runs as `anon` and PostgREST answers `42501 permission denied`.
///
/// The claim is granted server-side by the `grant-role-claim` Supabase Edge
/// Function (supabase/functions/grant-role-claim), which verifies the caller's
/// Firebase ID token and sets the claim on that account only. (Firebase
/// blocking functions in `functions/index.js` do the same on the Blaze plan;
/// either way works.) This helper:
///  1. returns the cached token if it already has `role: authenticated`;
///  2. otherwise asks the edge function to grant it (once at a time, with a
///     short pause after a failure), then force-refreshes the token;
///  3. if it is still missing, logs one clear message pointing at the fix.
class SupabaseToken {
  SupabaseToken._();

  static bool _warned = false;
  static Future<bool>? _granting;
  static DateTime? _lastGrantFailure;

  /// Asks the `grant-role-claim` edge function to set `role: authenticated`
  /// on the signed-in account. Returns true on success; never throws.
  static Future<bool> _requestRoleClaim(String idToken) async {
    try {
      final res = await http
          .post(
            Uri.parse('${SupabaseConfig.url}/functions/v1/grant-role-claim'),
            headers: {
              'Authorization': 'Bearer $idToken',
              'apikey': SupabaseConfig.anonKey,
              'Content-Type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// True when [jwt] carries `role: authenticated`. Never throws.
  @visibleForTesting
  static bool hasAuthenticatedRole(String? jwt) {
    if (jwt == null) return false;
    final parts = jwt.split('.');
    if (parts.length != 3) return false;
    try {
      final payload =
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'authenticated';
    } catch (_) {
      return false;
    }
  }

  /// Returns the bearer token for the signed-in user, or null when signed out
  /// (requests then go out as `anon`, enough for the public catalog).
  static Future<String?> fetch() async {
    final user = fb.FirebaseAuth.instance.currentUser;
    if (user == null) {
      _warned = false;
      return null;
    }

    var token = await user.getIdToken();
    if (hasAuthenticatedRole(token)) {
      _warned = false;
      return token;
    }

    // Ask the backend to grant the claim, one request at a time and not again
    // right after a failure (this runs before every Supabase request).
    final failedRecently = _lastGrantFailure != null &&
        DateTime.now().difference(_lastGrantFailure!) < const Duration(seconds: 30);
    if (token != null && !failedRecently) {
      final granted = await (_granting ??=
          _requestRoleClaim(token).whenComplete(() => _granting = null));
      if (granted) {
        _lastGrantFailure = null;
      } else {
        _lastGrantFailure = DateTime.now();
      }
    }

    // The claim only appears in a freshly minted token.
    try {
      token = await user.getIdToken(true);
    } catch (_) {
      // Offline or throttled: fall through with the cached token.
    }
    if (!hasAuthenticatedRole(token) && !_warned) {
      _warned = true;
      debugPrint(
        '[Supabase] Firebase ID token has no role=authenticated claim, so '
        'every request runs as anon and RLS will refuse it. Fix: deploy the '
        'grant-role-claim edge function and set its FIREBASE_SERVICE_ACCOUNT '
        'secret (see supabase/functions/README.md), then sign out and back in.',
      );
    }
    return token;
  }
}

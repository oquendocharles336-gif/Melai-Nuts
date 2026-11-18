import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/captcha_config.dart';
import '../config/supabase_config.dart';
import '../utils/app_error.dart';
import 'device_id_store.dart';

/// What the server said about a sign-in that is about to happen.
enum GuardOutcome {
  /// Go on with the Firebase sign-in.
  proceed,

  /// 15+ recent attempts for this e-mail, network or device: a captcha is needed first.
  /// Not a lockout: a solved captcha always lets the attempt through.
  captchaRequired,

  /// A captcha token was sent and refused (wrong, expired or already used): solve a new one.
  captchaRejected,
}

/// Client of the `auth-guard` Edge Function: the server-side sign-in counter.
///
/// Every password sign-in is announced first ([precheck]); a successful one then clears the
/// e-mail's counter ([reportSuccess], proven by the Firebase ID token). The counter lives on
/// the server, so reinstalling the app or clearing its data does not reset it.
///
/// What this does NOT stop on its own: a script that talks to Firebase Auth directly and
/// never calls this service. That is what Firebase App Check enforcement on Authentication is
/// for (docs/APP_CHECK.md); see the security notes in SECURITY.md.
class SignInGuardService {
  SignInGuardService._();
  static final SignInGuardService instance = SignInGuardService._();

  static const Duration _timeout = Duration(seconds: 10);

  bool get isConfigured => CaptchaConfig.authGuardUrl.startsWith('https://') || (kDebugMode && CaptchaConfig.authGuardUrl.isNotEmpty);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (SupabaseConfig.anonKey.isNotEmpty) 'apikey': SupabaseConfig.anonKey,
      };

  /// Any problem reaching the guard (offline, guard down) answers [GuardOutcome.proceed]:
  /// this is a gate for abusive volumes, and Firebase still checks the password and throttles
  /// on its side. A client that skips this call entirely is the App Check case (see above).
  Future<GuardOutcome> precheck({required String email, String? captchaToken}) async {
    if (!isConfigured) return GuardOutcome.proceed;
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('${CaptchaConfig.authGuardUrl}/sign-in/precheck'),
            headers: _headers,
            body: jsonEncode({
              'email': email.trim(),
              'device_id': await DeviceIdStore.instance.get(),
              if (captchaToken != null && captchaToken.isNotEmpty) 'captcha_token': captchaToken,
            }),
          )
          .timeout(_timeout);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'sign_in_guard:precheck');
      return GuardOutcome.proceed;
    }
    if (response.statusCode == 428) return GuardOutcome.captchaRequired;
    final code = _code(response);
    if (code == 'captcha_invalid' || code == 'captcha_unavailable') return GuardOutcome.captchaRejected;
    return GuardOutcome.proceed;
  }

  /// After a successful Firebase sign-in. Best effort, never throws.
  Future<void> reportSuccess(String idToken) async {
    if (!isConfigured) return;
    try {
      await http
          .post(
            Uri.parse('${CaptchaConfig.authGuardUrl}/sign-in/success'),
            headers: {..._headers, 'Authorization': 'Bearer $idToken'},
            body: jsonEncode({'device_id': await DeviceIdStore.instance.get()}),
          )
          .timeout(_timeout);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'sign_in_guard:success');
    }
  }

  static String? _code(http.Response r) {
    try {
      final body = jsonDecode(r.body);
      return body is Map && body['code'] is String ? body['code'] as String : null;
    } catch (_) {
      return null;
    }
  }
}

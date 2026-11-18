import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/captcha_config.dart';
import '../config/supabase_config.dart';
import '../utils/app_error.dart';

/// A user-facing failure of an account e-mail action (message is safe to show as-is).
class AccountEmailException implements Exception {
  final String message;

  /// The server's reason (cooldown, link_used, link_expired, weak_password, ...), or null.
  final String? code;
  final int? retryAfter;

  const AccountEmailException(this.message, {this.code, this.retryAfter});

  bool get needsCaptcha => code == 'captcha_required' || code == 'captcha_invalid' || code == 'captcha_unavailable';
  bool get isLinkProblem => code == 'link_used' || code == 'link_expired' || code == 'link_invalid';

  @override
  String toString() => message;
}

/// Password reset and e-mail change through our own e-mails (Supabase Edge Function
/// `account-email`, shared Melai Nuts template), instead of Firebase's e-mails.
///
///   POST {base}/password-reset/request {"email", "captcha_token"?}  (App Check or captcha)
///   POST {base}/password-reset/check   {"token"}
///   POST {base}/password-reset/confirm {"token", "password"}
///   POST {base}/email-change/request   {"new_email", "captcha_token"?} + `Bearer` (fresh ID token)
///
/// The links in the e-mails open `https://<website>/auth/action?mode=…&token=…`, in the app
/// through the Android App Link (ResetPasswordLinkScreen) or on the website. Firebase stays
/// the identity; the function changes the password / e-mail server-side.
class AccountEmailService {
  AccountEmailService._();
  static final AccountEmailService instance = AccountEmailService._();

  static const _timeout = Duration(seconds: 20);

  /// Never says whether the address has an account.
  Future<void> requestPasswordReset(String email, {String? captchaToken}) => _post(
    '/password-reset/request',
    {'email': email.trim().toLowerCase(), 'captcha_token': ?captchaToken},
    appCheck: true,
  );

  /// The account the link belongs to (the link is NOT used up). Returns the e-mail.
  Future<String> checkPasswordReset(String token) async {
    final j = await _post('/password-reset/check', {'token': token});
    return (j['email'] as String?) ?? '';
  }

  /// Sets the new password once; the account's other sign-ins end.
  Future<void> confirmPasswordReset(String token, String password) =>
      _post('/password-reset/confirm', {'token': token, 'password': password});

  /// From the NEW address's e-mail: applies the change. Returns the new e-mail.
  Future<String> confirmEmailChange(String token) async {
    final j = await _post('/email-change/confirm', {'token': token});
    return (j['email'] as String?) ?? '';
  }

  /// From the OLD address's "was this you?" e-mail: stops the pending change.
  Future<void> cancelEmailChange(String token) => _post('/email-change/cancel', {'token': token});

  /// Asks to move the signed-in account to [newEmail]: a confirmation link goes to the new
  /// address and a "was this you?" notice to the current one. [user] must have just
  /// re-entered the password (the server checks the sign-in time).
  Future<void> requestEmailChange(User user, String newEmail, {String? captchaToken}) async {
    final token = await user.getIdToken(true);
    await _post(
      '/email-change/request',
      {'new_email': newEmail.trim().toLowerCase(), 'captcha_token': ?captchaToken},
      idToken: token,
      appCheck: true,
    );
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {String? idToken, bool appCheck = false}) async {
    final base = CaptchaConfig.accountEmailUrl;
    final uri = Uri.tryParse('$base$path');
    if (base.isEmpty || uri == null || (uri.scheme != 'https' && !kDebugMode)) {
      throw const AccountEmailException('Account emails are not configured correctly.', code: 'not_configured');
    }
    String? appCheckToken;
    if (appCheck) {
      try {
        appCheckToken = await FirebaseAppCheck.instance.getToken();
      } catch (_) {
        appCheckToken = null; // the server then asks for the captcha
      }
    }
    final http.Response response;
    try {
      response = await http
          .post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (SupabaseConfig.anonKey.isNotEmpty) 'apikey': SupabaseConfig.anonKey,
          'Authorization': 'Bearer ${idToken ?? SupabaseConfig.anonKey}',
          if (appCheckToken != null && appCheckToken.isNotEmpty) 'X-Firebase-AppCheck': appCheckToken,
        },
        body: jsonEncode(body),
      )
          .timeout(_timeout);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'account_email_service:post');
      throw const AccountEmailException('Could not reach the server. Check your connection and try again.', code: 'offline');
    }
    Map<String, dynamic> j = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) j = decoded;
    } catch (_) {}
    if (response.statusCode >= 200 && response.statusCode < 300) return j;
    final reason = j['code'] is String ? j['code'] as String : null;
    final retryAfter = (j['retry_after'] as num?)?.toInt();
    throw AccountEmailException(
      messageFor(reason, response.statusCode, retryAfter: retryAfter, serverText: j['error'] as String?),
      code: reason,
      retryAfter: retryAfter,
    );
  }

  /// Customer-facing text for a server answer.
  @visibleForTesting
  static String messageFor(String? reason, int status, {int? retryAfter, String? serverText}) {
    switch (reason) {
      case 'captcha_required':
        return 'Please complete the security check.';
      case 'captcha_invalid':
        return 'The security check expired or failed. Please do it again.';
      case 'captcha_unavailable':
        return 'The security check is unavailable right now. Please try again in a moment.';
      case 'cooldown':
        return 'A link was just sent. Please wait ${retryAfter ?? 60} seconds before asking again.';
      case 'hourly_limit':
        return 'Too many requests. Please try again later.';
      case 'link_used':
        return 'This link was already used. Request a new one from "Forgot password?".';
      case 'link_expired':
        return 'This link has expired. Request a new one from "Forgot password?".';
      case 'link_invalid':
        return 'This link is not valid anymore. Open the link from the most recent Melai Nuts email.';
      case 'weak_password':
        return serverText ?? 'That password is too weak. Please choose a stronger one.';
      case 'reauth_required':
      case 'unauthorized':
        return 'Please enter your current password again.';
      case 'same_email':
        return 'That is already your email address.';
      case 'invalid_email':
        return 'Please enter a valid email address.';
      case 'email_taken':
        return "That email address can't be used. Please choose another one.";
    }
    if (status == 429) return 'Too many attempts. Please wait a moment and try again.';
    return 'Something went wrong. Please try again.';
  }
}
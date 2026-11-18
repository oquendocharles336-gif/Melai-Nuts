import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/captcha_config.dart';
import '../config/supabase_config.dart';
import '../utils/app_error.dart';

/// A user-facing verification failure (message is safe to show as-is).
class EmailVerificationException implements Exception {
  final String message;

  /// The server's reason (captcha_required, captcha_invalid, wrong_code, code_expired,
  /// code_used, too_many_attempts, cooldown, hourly_limit, ...), or null.
  final String? code;

  /// Seconds to wait, for cooldown / hourly_limit.
  final int? retryAfter;

  const EmailVerificationException(this.message, {this.code, this.retryAfter});

  /// The server wants (a new) captcha before it goes on.
  bool get needsCaptcha => code == 'captcha_required' || code == 'captcha_invalid' || code == 'captcha_unavailable';

  @override
  String toString() => message;
}

/// Proves that a new customer really owns the email address they registered
/// with, BEFORE a customer profile can be created.
///
/// The app-side screens are only the user interface. The actual enforcement is
/// server-side: `firestore.rules` refuses to create a customer profile unless
/// the caller's Firebase token has `email_verified == true`, and only the backend
/// (Firebase Admin, from the `email-verification` Edge Function) sets that flag.
/// A modified app therefore cannot skip verification.
///
/// ONE MODE: a 6-digit code, e-mailed by Melai Nuts' own sender (Supabase Edge Function
/// `email-verification`, branded e-mail, no link). Firebase's verification link e-mail is
/// not used anywhere any more.
///
///   POST {base}/send-code     body: {"captcha_token"?}   header X-Firebase-AppCheck (when available)
///   POST {base}/verify-code   body: {"code":"123456","captcha_token":"..."}
///   Both send `Authorization: Bearer <Firebase ID token>`; the server takes the e-mail
///   address and uid FROM THE TOKEN, never from the body.
///
/// The base URL defaults to {SUPABASE_URL}/functions/v1/email-verification
/// (override: --dart-define=EMAIL_API_BASE_URL=...).
class EmailVerificationService {
  EmailVerificationService._();
  static final EmailVerificationService instance = EmailVerificationService._();

  static const Duration _timeout = Duration(seconds: 15);

  String get _baseUrl => CaptchaConfig.emailApiBaseUrl;

  /// Always true: the 6-digit code is the only way (kept for the screens' wording).
  bool get usesCode => true;

  /// Emails a new code. A valid App Check token (sent automatically) or a solved
  /// [captchaToken] is required by the server; without either it answers captcha_required.
  Future<void> sendCode(User user, {String? captchaToken}) async {
    String? appCheck;
    try {
      appCheck = await FirebaseAppCheck.instance.getToken();
    } catch (caughtError) {
      // Not activated (web without a key, debug without a token): the captcha is the fallback.
      if (kDebugMode) debugPrint('App Check token unavailable: $caughtError');
    }
    await _post(
      user,
      '/send-code',
      {if (captchaToken != null && captchaToken.isNotEmpty) 'captcha_token': captchaToken},
      verifying: false,
      extraHeaders: {if (appCheck != null && appCheck.isNotEmpty) 'X-Firebase-AppCheck': appCheck},
    );
  }

  /// Submits [code] with a solved [captchaToken] (checked by the server BEFORE the code).
  Future<void> verify(User user, {required String? code, required String? captchaToken}) async {
    final trimmed = code?.trim() ?? '';
    if (!RegExp(r'^\d{6}$').hasMatch(trimmed)) {
      throw const EmailVerificationException('Please enter the 6-digit code.', code: 'invalid_code');
    }
    if (captchaToken == null || captchaToken.isEmpty) {
      throw const EmailVerificationException('Please complete the security check first.', code: 'captcha_required');
    }
    await _post(user, '/verify-code', {'code': trimmed, 'captcha_token': captchaToken}, verifying: true);
  }

  Future<void> _post(
    User user,
    String path,
    Map<String, dynamic> body, {
    required bool verifying,
    Map<String, String> extraHeaders = const {},
  }) async {
    if (_baseUrl.isEmpty) {
      throw const EmailVerificationException('Email verification is not configured correctly.', code: 'not_configured');
    }
    final uri = Uri.parse('$_baseUrl$path');
    // Never send an ID token over plain HTTP outside debug builds.
    if (uri.scheme != 'https' && !kDebugMode) {
      throw const EmailVerificationException('Email verification is not configured correctly.', code: 'not_configured');
    }
    final http.Response response;
    try {
      final token = await user.getIdToken();
      response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
              if (SupabaseConfig.anonKey.isNotEmpty) 'apikey': SupabaseConfig.anonKey,
              ...extraHeaders,
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'email_verification_service:post');
      // Timeouts, no network, bad URL, etc. Details intentionally not shown.
      throw const EmailVerificationException(
        'Could not reach the verification service. Check your connection and try again.',
        code: 'offline',
      );
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    String? reason;
    int? retryAfter;
    try {
      final j = jsonDecode(response.body);
      if (j is Map) {
        reason = j['code'] is String ? j['code'] as String : null;
        retryAfter = (j['retry_after'] as num?)?.toInt();
      }
    } catch (_) {}
    throw EmailVerificationException(messageFor(reason, status, verifying: verifying, retryAfter: retryAfter),
        code: reason, retryAfter: retryAfter);
  }

  /// Customer-facing text for a server answer (the server's own text is never shown raw).
  @visibleForTesting
  static String messageFor(String? reason, int status, {required bool verifying, int? retryAfter}) {
    switch (reason) {
      case 'captcha_required':
        return 'Please complete the security check.';
      case 'captcha_invalid':
        return 'The security check expired or failed. Please do it again.';
      case 'captcha_unavailable':
        return 'The security check is unavailable right now. Please try again in a moment.';
      case 'wrong_code':
        return 'That code is incorrect. Please check the email and try again.';
      case 'code_expired':
        return 'That code has expired. Tap "Resend code" to get a new one.';
      case 'code_used':
        return 'That code was already used. Tap "Resend code" to get a new one.';
      case 'too_many_attempts':
        return 'Too many wrong codes. Tap "Resend code" to get a new one.';
      case 'cooldown':
        return 'Please wait ${retryAfter ?? 60} seconds before asking for a new code.';
      case 'hourly_limit':
        return 'Too many codes were requested. Please try again later.';
      case 'invalid_code':
        return 'Please enter the 6-digit code.';
    }
    if (status == 429) return 'Too many attempts. Please wait a moment and try again.';
    if (status == 401) return 'Your sign-up session expired. Please sign in again.';
    return verifying ? 'We could not verify the code. Please try again.' : 'We could not send the code. Please try again.';
  }
}

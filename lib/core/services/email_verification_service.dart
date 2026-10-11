import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A user-facing verification failure (message is safe to show as-is).
class EmailVerificationException implements Exception {
  final String message;
  const EmailVerificationException(this.message);

  @override
  String toString() => message;
}

/// Proves that a new customer really owns the email address they registered
/// with, BEFORE a customer profile can be created.
///
/// The app-side screens are only the user interface. The actual enforcement is
/// server-side: `firestore.rules` refuses to create a customer profile unless
/// the caller's Firebase token has `email_verified == true`, and only Firebase
/// itself (verification link) or your backend (Admin SDK) can set that flag.
/// A modified app therefore cannot skip verification.
///
/// TWO MODES
///  * LINK mode (default, `EMAIL_API_BASE_URL` not set): Firebase emails a
///    verification link. Works today with no backend.
///  * CODE mode (`--dart-define=EMAIL_API_BASE_URL=https://api.example.com/auth`):
///    the app calls YOUR API to email a 6-digit code and to check it.
///
/// CODE-MODE API CONTRACT (both calls send `Authorization: Bearer <Firebase
/// ID token>`; the server must verify that token and take the email address and
/// uid FROM THE TOKEN — never from the request body — so nobody can make your
/// API email arbitrary addresses):
///
///   POST {base}/send-code     body: {}
///        200 -> a code was emailed          429 -> rate limited
///   POST {base}/verify-code   body: {"code":"123456"}
///        200 -> code correct; the server MUST then call the Firebase Admin SDK
///               `updateUser(uid, {emailVerified: true})`
///        400/401/403 -> wrong or expired code     429 -> too many attempts
///
/// See SECURITY.md for the required server-side protections (hashed codes,
/// short expiry, attempt limits, rate limits).
class EmailVerificationService {
  EmailVerificationService._();
  static final EmailVerificationService instance = EmailVerificationService._();

  static const String _baseUrl = String.fromEnvironment('EMAIL_API_BASE_URL');
  static const Duration _timeout = Duration(seconds: 15);

  /// True when your own API sends 6-digit codes; false = Firebase link mode.
  bool get usesCode => _baseUrl.isNotEmpty;

  /// Emails the code (CODE mode) or Firebase's verification link (LINK mode).
  Future<void> sendCode(User user) async {
    if (!usesCode) {
      try {
        await user.sendEmailVerification();
      } on FirebaseAuthException catch (e) {
        if (kDebugMode) debugPrint('sendEmailVerification code: ${e.code}');
        if (e.code == 'too-many-requests') {
          throw const EmailVerificationException(
            'Too many requests. Please wait a few minutes before trying again.',
          );
        }
        throw const EmailVerificationException(
          'We could not send the verification email. Please try again.',
        );
      }
      return;
    }
    await _post(user, '/send-code', const {}, verifying: false);
  }

  /// CODE mode: submits [code]. LINK mode: nothing to submit (the person taps
  /// the emailed link); the caller then reloads the user to see the result.
  Future<void> verify(User user, {String? code}) async {
    if (!usesCode) return;
    final trimmed = code?.trim() ?? '';
    if (!RegExp(r'^\d{6}$').hasMatch(trimmed)) {
      throw const EmailVerificationException('Please enter the 6-digit code.');
    }
    await _post(user, '/verify-code', {'code': trimmed}, verifying: true);
  }

  Future<void> _post(
    User user,
    String path,
    Map<String, dynamic> body, {
    required bool verifying,
  }) async {
    final uri = Uri.parse('$_baseUrl$path');
    // Never send an ID token over plain HTTP outside debug builds.
    if (uri.scheme != 'https' && !kDebugMode) {
      throw const EmailVerificationException(
        'Email verification is not configured correctly.',
      );
    }
    try {
      final token = await user.getIdToken();
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      final status = response.statusCode;
      if (status >= 200 && status < 300) return;
      if (status == 429) {
        throw const EmailVerificationException(
          'Too many attempts. Please wait a moment and try again.',
        );
      }
      if (verifying && (status == 400 || status == 401 || status == 403)) {
        throw const EmailVerificationException(
          'That code is incorrect or has expired.',
        );
      }
      throw EmailVerificationException(
        verifying
            ? 'We could not verify the code. Please try again.'
            : 'We could not send the code. Please try again.',
      );
    } on EmailVerificationException {
      rethrow;
    } catch (_) {
      // Timeouts, no network, bad URL, etc. Details intentionally not shown.
      throw const EmailVerificationException(
        'Could not reach the verification service. Check your connection and try again.',
      );
    }
  }
}

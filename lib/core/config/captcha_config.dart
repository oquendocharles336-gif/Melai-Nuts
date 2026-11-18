import 'supabase_config.dart';

/// Cloudflare Turnstile + the server-side auth endpoints (Supabase Edge Functions).
///
/// Build-time values (dart-define, like env/firebase.json):
///   CAPTCHA_PAGE_URL       the website's captcha page, e.g. https://shop.example.com/captcha
///                          (renders the Turnstile widget with the PUBLIC site key from the
///                          website's .env; the secret key exists only in Supabase secrets).
///   EMAIL_API_BASE_URL     optional; default {SUPABASE_URL}/functions/v1/email-verification
///   AUTH_GUARD_URL         optional; default {SUPABASE_URL}/functions/v1/auth-guard
///   ACCOUNT_EMAIL_URL      optional; default {SUPABASE_URL}/functions/v1/account-email
///
/// With no CAPTCHA_PAGE_URL the app cannot show a captcha: steps that require one tell the
/// person so (the server still refuses without a valid token).
class CaptchaConfig {
  CaptchaConfig._();

  static const String pageUrl = String.fromEnvironment('CAPTCHA_PAGE_URL');
  static const String _emailApi = String.fromEnvironment('EMAIL_API_BASE_URL');
  static const String _guard = String.fromEnvironment('AUTH_GUARD_URL');
  static const String _accountEmail = String.fromEnvironment('ACCOUNT_EMAIL_URL');

  static bool get captchaAvailable => pageUrl.startsWith('https://');

  static String get emailApiBaseUrl =>
      _emailApi.isNotEmpty ? _emailApi : (SupabaseConfig.url.isEmpty ? '' : '${SupabaseConfig.url}/functions/v1/email-verification');

  static String get authGuardUrl =>
      _guard.isNotEmpty ? _guard : (SupabaseConfig.url.isEmpty ? '' : '${SupabaseConfig.url}/functions/v1/auth-guard');

  /// Password reset / e-mail change / security notices (our own e-mails, no Firebase e-mails).
  static String get accountEmailUrl =>
      _accountEmail.isNotEmpty ? _accountEmail : (SupabaseConfig.url.isEmpty ? '' : '${SupabaseConfig.url}/functions/v1/account-email');

  /// The page for one widget action (sign_in, send_code, verify_email, reset_password, change_email).
  static Uri pageFor(String action) => Uri.parse(pageUrl).replace(queryParameters: {'action': action, 'app': '1'});
}

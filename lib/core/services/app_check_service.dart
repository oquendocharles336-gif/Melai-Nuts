import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Firebase App Check: proves to Firebase (Auth, Firestore) that requests come
/// from THIS app on a genuine device, not from a clone or a script using the
/// public API key. See docs/APP_CHECK.md for the console steps (register the
/// providers, then turn on enforcement).
///
/// Providers:
///  * Android release: Play Integrity. Debug builds: the debug provider (add the
///    debug token printed in logcat to the console's "Manage debug tokens").
///  * iOS / macOS release: App Attest with DeviceCheck fallback; debug: debug provider.
///  * Web: reCAPTCHA v3 with the site key from
///    `--dart-define=FIREBASE_APPCHECK_WEB_RECAPTCHA_SITE_KEY=...` (no key = not activated on web).
///
/// Activation never blocks start-up: if it fails, the app still runs and the
/// failure is logged (with enforcement ON, Firebase then refuses the requests,
/// which is the point).
class AppCheckService {
  AppCheckService._();

  static const String _webSiteKey = String.fromEnvironment('FIREBASE_APPCHECK_WEB_RECAPTCHA_SITE_KEY');
  static const String _debugToken = String.fromEnvironment('FIREBASE_APPCHECK_DEBUG_TOKEN');

  static Future<void> activate() async {
    if (kIsWeb && _webSiteKey.isEmpty) {
      debugPrint('App Check: FIREBASE_APPCHECK_WEB_RECAPTCHA_SITE_KEY is not set; web is not attested.');
      return;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) return; // not supported there
    final debugToken = _debugToken.isEmpty ? null : _debugToken;
    try {
      await FirebaseAppCheck.instance.activate(
        providerWeb: _webSiteKey.isEmpty ? null : ReCaptchaV3Provider(_webSiteKey),
        providerAndroid: kReleaseMode
            ? const AndroidPlayIntegrityProvider()
            : AndroidDebugProvider(debugToken: debugToken),
        providerApple: kReleaseMode
            ? const AppleAppAttestWithDeviceCheckFallbackProvider()
            : AppleDebugProvider(debugToken: debugToken),
      );
      await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(true);
    } catch (e) {
      debugPrint('App Check could not be activated: $e');
    }
  }
}

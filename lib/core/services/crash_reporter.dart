import 'dart:ui';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Crash and error reporting through Firebase Crashlytics (Android, iOS,
/// macOS). On other platforms, and in tests, everything goes to the debug log
/// only. Reports never contain customer data: only the error, its stack and a
/// short code location ("context"); the signed-in account is identified by its
/// Firebase UID only.
class CrashReporter {
  CrashReporter._();

  /// Turned on by [init]; false in unit tests and unsupported platforms.
  static bool _enabled = false;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Call once after `Firebase.initializeApp`. Uncaught Flutter and async
  /// errors become fatal reports. Collection is off in debug builds.
  static Future<void> init() async {
    if (!_supported) return;
    try {
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(!kDebugMode);
      FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      _enabled = true;
    } catch (e) {
      debugPrint('Crash reporting could not start: $e');
    }
  }

  /// A caught, unexpected error the app recovered from.
  static void recordNonFatal(Object error, StackTrace stack, {required String context}) {
    debugPrint('[error:$context] ${error.runtimeType}: $error');
    if (!_enabled) return;
    FirebaseCrashlytics.instance.recordError(error, stack, reason: context, fatal: false);
  }

  /// An expected condition (offline, timeout, signed out...): kept as a
  /// breadcrumb that shows up next to the next report, never a report itself.
  static void breadcrumb(String message) {
    if (kDebugMode) debugPrint('[breadcrumb] $message');
    if (!_enabled) return;
    FirebaseCrashlytics.instance.log(message);
  }

  /// The signed-in account (Firebase UID) or '' after sign-out.
  static void setUser(String? firebaseUid) {
    if (!_enabled) return;
    FirebaseCrashlytics.instance.setUserIdentifier(firebaseUid ?? '');
  }
}

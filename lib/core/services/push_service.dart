import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_error.dart';
import 'supabase_service.dart';

/// Push notifications (order status, refund decisions, low stock, expiring
/// batches). They are CREATED ONLY BY THE DATABASE (migration
/// 20261021000000_push_notifications.sql) and sent by the `push-dispatch` Edge
/// Function; this app only registers its device token for the signed-in
/// account and removes it on sign-out. Android, iOS and macOS only.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  StreamSubscription<String>? _refresh;
  String? _registeredToken;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  String get _platform => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'ios',
        TargetPlatform.macOS => 'macos',
        _ => 'android',
      };

  /// After sign-in: ask permission once (Android 13+ / iOS), then register.
  Future<void> onSignedIn() async {
    if (!_supported) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      // Shown by the system while the app is open, too (iOS / macOS).
      await messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token != null) await _register(token);
      await _refresh?.cancel();
      _refresh = messaging.onTokenRefresh.listen((t) => unawaited(_register(t)));
    } catch (e, st) {
      AppErrors.report(e, st, 'push_service:onSignedIn');
    }
  }

  Future<void> _register(String token) async {
    await SupabaseService.instance.client
        .rpc('register_push_token', params: {'p_token': token, 'p_platform': _platform});
    _registeredToken = token;
  }

  /// Before sign-out (while still signed in): this device stops receiving the
  /// account's pushes.
  Future<void> onSigningOut() async {
    if (!_supported) return;
    await _refresh?.cancel();
    _refresh = null;
    final token = _registeredToken;
    _registeredToken = null;
    if (token == null) return;
    try {
      await SupabaseService.instance.client.rpc('unregister_push_token', params: {'p_token': token});
      await FirebaseMessaging.instance.deleteToken();
    } catch (e, st) {
      AppErrors.report(e, st, 'push_service:onSigningOut');
    }
  }
}

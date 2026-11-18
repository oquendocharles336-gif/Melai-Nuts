import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/customer_data_store.dart';
import '../../core/services/staff_store.dart';
import '../../core/utils/app_error.dart';
import '../../data/models/notification_item.dart';
import 'notification_targets.dart';
import 'screens/notification_detail_screen.dart';

/// Where a tapped push should go, worked out only from what the push carries
/// (`push-dispatch`: `kind`, plus the row's `notification_id`, `category` and,
/// for staff, `reference`).
class PushTap {
  final bool forStaff;
  final String? category;
  final String? notificationId;

  /// The order this push is about: staff pushes name it in `reference`, and
  /// customer pushes name it in their text.
  final String? orderId;

  /// Staff pushes: the row's `reference` (an order id, `expiry:<batch>`, ...).
  final String? reference;
  final String? title;
  final String? body;

  const PushTap({
    required this.forStaff,
    this.category,
    this.notificationId,
    this.orderId,
    this.reference,
    this.title,
    this.body,
  });

  factory PushTap.from(Map<String, dynamic> data, {String? title, String? body}) {
    final forStaff = (data['kind'] as String? ?? '').startsWith('staff.');
    final reference = data['reference'] as String?;
    final category = data['category'] as String?;
    final inText = NotificationTargets.orderIdIn(title, body);
    return PushTap(
      forStaff: forStaff,
      category: category,
      notificationId: data['notification_id'] as String?,
      orderId: forStaff ? (category == 'order' ? (reference ?? inText) : null) : inText,
      reference: forStaff ? reference : null,
      title: title,
      body: body,
    );
  }
}

/// Opens the right screen when a push notification is tapped. Android removes
/// the notification itself when it is tapped: FCM marks it auto-cancel.
class PushTapRouter {
  PushTapRouter._();
  static final PushTapRouter instance = PushTapRouter._();

  PushTap? _pending;
  bool _portalReady = false;
  bool _started = false;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Call once at startup, after Firebase is ready.
  Future<void> start() async {
    if (_started || !_supported) return;
    _started = true;
    try {
      FirebaseMessaging.onMessageOpenedApp.listen(_onTapped);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _onTapped(initial);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'push_tap_router:start');
    }
  }

  /// A signed-in portal is on screen, so a tap can open something over it. A tap
  /// that started the app waits for this: the splash screen replaces the route.
  void portalReady() {
    _portalReady = true;
    final pending = _pending;
    _pending = null;
    if (pending != null) unawaited(_open(pending));
  }

  void _onTapped(RemoteMessage message) {
    final tap = PushTap.from(
      message.data,
      title: message.notification?.title,
      body: message.notification?.body,
    );
    if (_portalReady) {
      unawaited(_open(tap));
    } else {
      _pending = tap;
    }
  }

  Future<void> _open(PushTap tap) async {
    final navigator = AppRoutes.navigatorKey.currentState;
    if (navigator == null || AuthService.instance.currentFirebaseUser == null) return;
    try {
      if (tap.forStaff) {
        await _openForStaff(navigator, tap);
      } else {
        await _openForCustomer(navigator, tap);
      }
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'push_tap_router:open');
    }
  }

  /// The same places as tapping the notification inside the app.
  Future<void> _openForStaff(NavigatorState navigator, PushTap tap) async {
    final store = StaffStore.instance;
    await store.ensureStarted();
    final id = tap.notificationId;
    if (id != null) unawaited(store.markNotificationRead(id));
    String? reference = tap.category == 'order' ? tap.orderId : tap.reference;
    if (reference == null && id != null) {
      // Non-order pushes carry no reference; read it from the stored row
      // (e.g. `expiry:<batch>` opens Expiring Soon instead of Low Stock).
      for (final n in store.notifications) {
        if (n.id == id) reference = n.reference;
      }
    }
    final opened = await NotificationTargets.openForStaff(
      navigator,
      category: tap.category,
      reference: reference,
      title: tap.title,
      body: tap.body,
    );
    if (!opened) navigator.pushNamed(AppRoutes.staffNotifications);
  }

  Future<void> _openForCustomer(NavigatorState navigator, PushTap tap) async {
    final store = CustomerDataStore.instance;
    final id = tap.notificationId;
    if (id != null) unawaited(store.markNotificationRead(id));
    if (await NotificationTargets.openCustomerOrder(navigator, tap.orderId)) return;
    NotificationItem? item;
    for (final n in store.notifications) {
      if (n.id == id) item = n;
    }
    if (item != null) {
      final found = item;
      navigator.push(MaterialPageRoute(builder: (_) => NotificationDetailScreen(item: found)));
      return;
    }
    navigator.pushNamed(AppRoutes.notificationCenter);
  }
}

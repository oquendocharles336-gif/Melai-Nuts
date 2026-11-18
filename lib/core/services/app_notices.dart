import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/routes.dart';
import '../../data/models/inventory_batch.dart';
import '../../data/models/staff_models.dart';
import '../../features/customer/cart_controller.dart';
import '../../features/notifications/notification_targets.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import 'auth_service.dart';
import 'connectivity_service.dart';
import 'staff_offline_store.dart';
import 'staff_session_store.dart';
import 'staff_store.dart';
import 'sync_service.dart';

/// App-wide notifications that replace the old permanent top banners:
///
///  * connection lost / connection restored;
///  * changes saved on this device have all synced (or some could not);
///  * the customer's cart has not synced yet / has synced;
///  * a stock batch has reached its expiry date (staff with the inventory
///    permission; product, branch, batch and expired quantity).
///
/// Each one is shown as a short toast over the current screen and — for
/// staff — added to the staff notification list (same list, badge and tap
/// targets as the server's notifications, see [StaffStore.addLocalNotification]).
///
/// NO SPAM: one notice per state CHANGE (going offline twice in a row is one
/// notice), a connection that drops and returns within a few seconds says
/// nothing at all, connection notices replace each other in the list instead
/// of piling up, and each expired batch is announced once ever (SQLite
/// `staff_expiry_alerts`).
class AppNotices {
  AppNotices._();
  static final AppNotices instance = AppNotices._();

  /// How long a connection change must last before it is announced.
  static const Duration settle = Duration(seconds: 3);

  bool _started = false;
  AppLifecycleListener? _lifecycle;
  Timer? _connectionTimer;

  /// The connection state last announced (null = nothing announced yet).
  bool? _announcedOnline;
  bool _sawPending = false;
  int _lastFailed = 0;
  bool _cartWasUnsynced = false;
  List<InventoryBatch>? _checkedBatches;
  Future<void> _expiryChain = Future<void>.value();

  /// Call once at start-up, before connectivity starts reporting.
  void start() {
    if (_started) return;
    _started = true;
    ConnectivityService.instance.addListener(_onConnectivity);
    SyncService.instance.addListener(_onSync);
    CartController.instance.addListener(_onCart);
    StaffStore.instance.addListener(_onStaffData);
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  /// Stops listening (tests / hot restart).
  void stop() {
    if (!_started) return;
    _started = false;
    ConnectivityService.instance.removeListener(_onConnectivity);
    SyncService.instance.removeListener(_onSync);
    CartController.instance.removeListener(_onCart);
    StaffStore.instance.removeListener(_onStaffData);
    _lifecycle?.dispose();
    _lifecycle = null;
    _connectionTimer?.cancel();
    _connectionTimer = null;
  }

  bool get _isStaff {
    final uid = AuthService.instance.currentFirebaseUser?.uid;
    return uid != null && StaffSessionStore.instance.ownerUid == uid && StaffStore.instance.profile != null;
  }

  // ---- Connection -----------------------------------------------------------

  void _onConnectivity() {
    final online = ConnectivityService.instance.isOnline;
    _connectionTimer?.cancel();
    if (_announcedOnline == null) {
      // First report after start: only "offline" is worth saying.
      if (online) {
        _announcedOnline = true;
        return;
      }
    }
    if (online == _announcedOnline) return; // flapped back: nothing to say
    _connectionTimer = Timer(settle, () {
      if (ConnectivityService.instance.isOnline != online || online == _announcedOnline) return;
      _announcedOnline = online;
      online ? _announceOnline() : _announceOffline();
    });
  }

  void _announceOffline() {
    final staff = _isStaff;
    const title = "You're offline";
    final body = staff
        ? 'Showing saved data. Changes you make are saved on this device and sync when you reconnect. '
            'Orders, payments and refunds that need the server wait until then.'
        : 'Showing saved data. Orders, payments and refunds can\'t be placed until you reconnect.';
    _toast(Icons.cloud_off_rounded, AppColors.textMuted, '$title. $body');
    if (staff) _addStaff('local:connection', 'system', title, body);
  }

  void _announceOnline() {
    final pending = SyncService.instance.pendingCount;
    final staff = _isStaff;
    const title = 'Back online';
    final body = staff && pending > 0
        ? 'Sending ${_plural(pending, 'saved change')} to the server…'
        : 'Showing live data again.';
    _toast(Icons.cloud_done_rounded, AppColors.success, '$title. $body');
    if (staff) _addStaff('local:connection', 'system', title, body);
  }

  // ---- Sync -------------------------------------------------------------------

  void _onSync() {
    final sync = SyncService.instance;
    final pending = sync.pendingCount;
    final failed = sync.failedCount;
    if (pending > 0) _sawPending = true;
    if (!_isStaff) {
      _lastFailed = failed;
      return;
    }
    if (failed > _lastFailed) {
      const title = 'Some changes could not sync';
      final body = 'The server refused ${_plural(failed, 'saved change')}. '
          'Open the sync queue (cloud icon at the top) to retry or discard.';
      _toast(Icons.error_outline_rounded, AppColors.error, body);
      _addStaff('local:sync', 'system', title, body);
    } else if (_sawPending && pending == 0 && failed == 0) {
      _sawPending = false;
      const title = 'All changes synced';
      const body = 'Everything saved on this device while offline is now on the server.';
      _toast(Icons.cloud_done_rounded, AppColors.success, title);
      _addStaff('local:sync', 'system', title, body);
    }
    _lastFailed = failed;
  }

  // ---- Customer cart -----------------------------------------------------------

  void _onCart() {
    if (_isStaff) return;
    final unsynced = CartController.instance.hasUnsyncedChanges;
    if (unsynced == _cartWasUnsynced) return;
    _cartWasUnsynced = unsynced;
    if (unsynced) {
      _toast(Icons.shopping_cart_outlined, AppColors.warning, "Your cart changes haven't synced to your account yet.");
    } else if (ConnectivityService.instance.isOnline) {
      _toast(Icons.shopping_cart_checkout_rounded, AppColors.success, 'Your cart is synced to your account.');
    }
  }

  // ---- Expired stock -------------------------------------------------------------

  void _onStaffData() {
    final store = StaffStore.instance;
    if (store.profile == null) {
      _checkedBatches = null;
      return;
    }
    if (identical(store.batches, _checkedBatches)) return;
    _checkedBatches = store.batches;
    unawaited(checkExpiredStock());
  }

  void _onResume() {
    final store = StaffStore.instance;
    if (store.profile == null) return;
    // A new day may have started: check the dates again, then refresh.
    unawaited(checkExpiredStock());
    unawaited(store.refreshInventory());
  }

  /// Announces every batch with stock that has reached its expiry date, once
  /// per batch. Runs on app start, on resume and after every sync / refresh
  /// (whenever the inventory changes). Checks never overlap.
  Future<void> checkExpiredStock() => _expiryChain = _expiryChain.then((_) => _checkExpired()).catchError((_) {});

  Future<void> _checkExpired() async {
    final store = StaffStore.instance;
    final scope = store.profile?.uid;
    if (scope == null || !store.canManageInventory || !store.inventoryState.loaded) return;
    final branchName = store.activeBranchName;
    for (final b in List<InventoryBatch>.from(store.batches)) {
      if (b.quantity <= 0 || b.isLocal || !b.isExpired) continue;
      if (!await StaffOfflineStore.instance.claimExpiryAlert(scope, b.id, b.quantity)) continue;
      if (store.profile?.uid != scope) return; // signed out meanwhile
      final product = [
        if (b.productName.isNotEmpty) b.productName,
        if (b.variantLabel.isNotEmpty) b.variantLabel,
      ].join(' • ');
      final branch = b.branch.isNotEmpty ? b.branch : branchName;
      final title = 'Expired stock: ${product.isEmpty ? 'batch ${b.batchCode}' : product}';
      final body = '${_plural(b.quantity, 'unit')} of batch ${b.batchCode} at $branch expired on '
          '${DateFormat('MMM d, y').format(b.expirationDate)}. Tap to remove them from stock.';
      await store.addLocalNotification(StaffNotification(
        id: 'local:expired:${b.id}',
        category: 'inventory',
        title: title,
        body: body,
        reference: '${NotificationTargets.expiredPrefix}${b.id}',
        read: false,
        createdAt: DateTime.now(),
      ));
      _toast(
        Icons.event_busy_rounded,
        AppColors.error,
        '$title — ${_plural(b.quantity, 'unit')} expired.',
        actionLabel: 'Adjust',
        onAction: () {
          final nav = AppRoutes.navigatorKey.currentState;
          if (nav == null) return;
          unawaited(store.markNotificationRead('local:expired:${b.id}'));
          unawaited(NotificationTargets.openExpiredBatch(nav, b.id));
        },
      );
    }
  }

  // ---- Helpers ---------------------------------------------------------------------

  static String _plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  void _addStaff(String id, String category, String title, String body) {
    unawaited(StaffStore.instance.addLocalNotification(StaffNotification(
      id: id,
      category: category,
      title: title,
      body: body,
      reference: null,
      read: false,
      createdAt: DateTime.now(),
    )));
  }

  void _toast(IconData icon, Color color, String text, {String? actionLabel, VoidCallback? onAction}) {
    final messenger = AppRoutes.messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: actionLabel == null ? 4 : 8),
        content: Row(
          children: [
            Icon(icon, color: color == AppColors.textMuted ? Colors.white : color, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: AppTextStyles.bodyMd.copyWith(color: Colors.white))),
          ],
        ),
        action: actionLabel == null || onAction == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction),
      ));
  }
}

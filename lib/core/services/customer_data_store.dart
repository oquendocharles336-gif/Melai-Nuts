import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../data/models/customer_profile.dart';
import '../../data/models/loyalty.dart';
import '../../data/models/notification_item.dart';
import '../../data/models/order.dart';
import '../../data/models/payment.dart';
import '../../data/models/refund.dart';
import '../../data/repositories/customer_profile_repository.dart';
import '../../data/repositories/loyalty_repository.dart';
import '../../data/repositories/notifications_repository.dart';
import '../../data/repositories/orders_repository.dart';
import '../../data/repositories/payments_repository.dart';
import '../../data/repositories/refunds_repository.dart';
import '../utils/app_error.dart';
import 'checkout_attempt_store.dart';
import 'connectivity_service.dart';
import 'local_cache_service.dart';
import 'offline_read_cache_client.dart';
import 'pending_writes_service.dart';

/// Single source of truth for every customer-scoped record (orders,
/// loyalty, notifications, refunds, payments, profile, addresses), loaded
/// from Supabase after sign-in.
///
/// This store owns its own typed lists — nothing here reads or writes the
/// legacy `dummy_data` globals, so the customer app does not depend on them.
///
/// Data honesty rules:
///  * Values come from the server (live) or from the last live response
///    kept by [OfflineReadCacheClient] (labelled as saved data through
///    [CacheStatus]); nothing is invented.
///  * Local optimistic changes (mark read, profile edit) are only ever
///    applied together with a durable [PendingWritesService] entry, and the
///    outcome reported to the UI says whether the server actually accepted
///    them.
///
/// A [ChangeNotifier] so screens can wrap their body in a
/// `ListenableBuilder(listenable: CustomerDataStore.instance, ...)` — the
/// same pattern this app already uses for [CartController].
class CustomerDataStore extends ChangeNotifier {
  CustomerDataStore._();
  static final CustomerDataStore instance = CustomerDataStore._();

  /// The customer whose records were last loaded *successfully*.
  String? _uid;

  /// The customer a load was most recently requested for, whether or not it
  /// succeeded — this is what [refresh]/[retry] reload after a failure.
  String? _requestedUid;

  Future<void>? _inFlight;
  bool _reloadQueued = false;

  /// Bumped by [clear] so a response that arrives after sign-out is dropped
  /// instead of repopulating the lists with the previous customer's data.
  int _generation = 0;

  bool _loading = false;

  /// True while any customer record load is running.
  bool get isLoading => _loading;

  /// True while loading and nothing has been loaded yet — screens should show
  /// their loading state (not an empty state) in this case.
  bool get isInitialLoading => _loading && !hasLoaded;

  AppError? _error;

  /// Customer-safe error from the most recent load, or null if it succeeded.
  /// When non-null and [hasLoaded] is false, screens should show an error
  /// state with a retry; when [hasLoaded] is true the last good data is still
  /// in the lists and a stale-data notice is enough.
  AppError? get error => _error;

  /// True once ALL of the customer's records have loaded (live, or from the
  /// saved copy when the server can't be reached — see [CacheStatus]).
  bool get hasLoaded => _uid != null;

  int pointsBalance = 0;

  /// Pesos per point earned (owner setting; 50 until the server says otherwise).
  double earnPesosPerPoint = 50;
  CustomerProfile? profile;
  List<CustomerAddress> addresses = [];

  final List<Order> orders = <Order>[];
  final List<LoyaltyPointTransaction> loyaltyTransactions = <LoyaltyPointTransaction>[];
  final List<RewardItem> rewards = <RewardItem>[];
  final List<NotificationItem> notifications = <NotificationItem>[];
  final List<RefundRequest> refunds = <RefundRequest>[];
  final List<PaymentTransaction> payments = <PaymentTransaction>[];

  // ---- Realtime (Supabase) ------------------------------------------------
  // One subscription per customer-owned table that changes on the server
  // without the customer doing anything: notifications, orders (status /
  // rider / ETA) and payments (status). All are cancelled in [stopRealtime]
  // (sign-out via [clear], account switch, [dispose]) so nothing leaks.
  StreamSubscription<List<NotificationItem>>? _notificationsSub;
  StreamSubscription<List<Map<String, dynamic>>>? _ordersSub;
  StreamSubscription<List<PaymentTransaction>>? _paymentsSub;
  String? _realtimeUid;
  bool _realtimePaused = false;

  /// `id -> "status|updated_at"` of the orders last seen on the stream, used
  /// to tell a real change from the stream re-sending an unchanged snapshot.
  final Map<String, String> _orderStamps = <String, String>{};
  bool _orderRefreshRunning = false;
  bool _orderRefreshQueued = false;

  /// True when a live subscription reported an error (e.g. connection lost).
  /// Data already on screen is still the last known server data, and it is
  /// re-synced by [refresh] when connectivity returns. Cleared on the next
  /// live event.
  bool get realtimePaused => _realtimePaused;

  /// When every record was last refreshed live in a single fully-successful
  /// cycle. Null until that has happened this session.
  DateTime? lastSyncedAt;

  Order? get activeOrder {
    for (final order in orders) {
      if (order.status.isActive) return order;
    }
    return null;
  }

  PaymentTransaction? paymentForOrder(String orderId) {
    for (final p in payments) {
      if (p.orderId == orderId) return p;
    }
    return null;
  }

  int get unreadNotificationCount => notifications.where((n) => !n.read).length;

  /// The address to prefill on checkout / show as "delivery address" on the
  /// profile screen: the one marked default, or the first saved address if
  /// none is marked, or null if the customer hasn't saved any yet.
  CustomerAddress? get defaultAddress {
    if (addresses.isEmpty) return null;
    for (final a in addresses) {
      if (a.isDefault) return a;
    }
    return addresses.first;
  }

  String? _fallbackName;
  String? _fallbackEmail;

  /// Records who is signing in (no network) so that [refresh]/[retry] work
  /// even if the very first load — or the profile-creation step before it —
  /// failed. Call right after sign-in, before any load.
  void rememberCustomer({
    required String firebaseUid,
    required String fallbackName,
    required String fallbackEmail,
  }) {
    _requestedUid = firebaseUid;
    _fallbackName = fallbackName;
    _fallbackEmail = fallbackEmail;
  }

  /// Loads (or reloads) everything for [firebaseUid]. Safe to call multiple
  /// times — screens call this from `initState` and it's a cheap no-op if
  /// already loaded for the same customer (use [refresh] to force a reload).
  /// Concurrent calls share one request.
  ///
  /// Never throws; check [error] / [hasLoaded] for the outcome.
  Future<void> loadForCustomer(String firebaseUid) {
    if (_uid == firebaseUid && !_loading) return Future.value();
    return _load(firebaseUid);
  }

  /// Forces a reload for the current customer. Also works after a failed
  /// first load (when [hasLoaded] is still false). With [throwOnError] the
  /// [AppError] is rethrown so pull-to-refresh handlers can show a snackbar.
  Future<void> refresh({bool throwOnError = false}) async {
    final uid = _uid ?? _requestedUid;
    if (uid == null) return;
    await _load(uid);
    final e = _error;
    if (throwOnError && e != null) throw e;
  }

  /// Retry after a failed load (same as [refresh]).
  Future<void> retry() => refresh();

  /// Runs at most one load at a time. A request that arrives mid-load is
  /// coalesced into one follow-up load (so a change made while loading is
  /// never missed and loads never interleave).
  Future<void> _load(String firebaseUid) {
    // Always remember the LATEST customer asked for, so a follow-up load
    // queued behind a running one can never reuse a stale uid.
    _requestedUid = firebaseUid;
    final running = _inFlight;
    if (running != null) {
      _reloadQueued = true;
      return running;
    }
    late final Future<void> future;
    future = _runLoads().whenComplete(() {
      // Only clear our own marker: a load invalidated by sign-out must not
      // wipe the marker of the next session's load.
      if (identical(_inFlight, future)) _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<void> _runLoads() async {
    do {
      _reloadQueued = false;
      final uid = _requestedUid;
      if (uid == null) return;
      await _loadOnce(uid);
    } while (_reloadQueued);
  }

  Future<void> _loadOnce(String firebaseUid) async {
    final generation = _generation;
    _loading = true;
    _error = null;
    // Deferred: screens call this from `initState`, i.e. mid-build, and a
    // synchronous notify there would throw "setState() called during build".
    scheduleMicrotask(notifyListeners);
    final serveMark = CacheStatus.instance.serveCounter;
    var failures = 0;
    AppError? firstFailure;

    Future<T?> guard<T>(Future<T> Function() action) async {
      try {
        return await AppErrors.guard(action, timeout: AppErrors.rpcTimeout);
      } catch (e) {
        failures++;
        firstFailure ??= AppErrors.from(e);
        return null;
      }
    }

    try {
      if (ConnectivityService.instance.isOnline) {
        // Order matters: push queued customer changes first so the fetch
        // below reads them back, and settle any checkout whose outcome was
        // never seen before we show order history.
        try {
          await PendingWritesService.instance.flush(firebaseUid);
        } catch (_) {}
        try {
          await CheckoutAttemptStore.instance.resolveUnconfirmed(firebaseUid);
        } catch (_) {}
      }

      // The profile row is created on first sign-in. If that step failed
      // earlier (e.g. offline), redo it here so Retry recovers fully.
      final fallbackEmail = _fallbackEmail;
      if (profile == null && fallbackEmail != null) {
        await guard(() async {
          final created = await CustomerProfileRepository.instance.ensureProfile(
            firebaseUid: firebaseUid,
            fallbackName: _fallbackName ?? '',
            fallbackEmail: fallbackEmail,
          );
          if (generation == _generation) profile = _withPendingProfileChange(firebaseUid, created);
        });
      }

      final results = await Future.wait<Object?>([
        guard(() => OrdersRepository.instance.fetchOrders(firebaseUid)),
        guard(() => LoyaltyRepository.instance.fetchBalance(firebaseUid)),
        guard(() => LoyaltyRepository.instance.fetchTransactions(firebaseUid)),
        guard(() => LoyaltyRepository.instance.fetchRewards()),
        guard(() => NotificationsRepository.instance.fetchAll(firebaseUid)),
        guard(() => RefundsRepository.instance.fetchAll(firebaseUid)),
        guard(() => PaymentsRepository.instance.fetchAll(firebaseUid)),
        guard(() => CustomerProfileRepository.instance.fetchAddresses(firebaseUid)),
        guard<CustomerProfile?>(() => CustomerProfileRepository.instance.fetchProfile(firebaseUid)),
        guard(() => LoyaltyRepository.instance.fetchEarnPesosPerPoint()),
      ]);

      // Signed out (or switched account) while this was loading: drop it —
      // never write one account's data into the next one's session.
      if (generation != _generation) return;

      // A record type that failed keeps whatever was last loaded — never blanked.
      final fetchedOrders = results[0] as List<Order>?;
      if (fetchedOrders != null) {
        orders
          ..clear()
          ..addAll(fetchedOrders);
      }
      final balance = results[1] as int?;
      if (balance != null) pointsBalance = balance;
      final earnRate = results[9] as double?;
      if (earnRate != null && earnRate >= 1) earnPesosPerPoint = earnRate;
      final txs = results[2] as List<LoyaltyPointTransaction>?;
      if (txs != null) {
        loyaltyTransactions
          ..clear()
          ..addAll(txs);
      }
      final rewardList = results[3] as List<RewardItem>?;
      if (rewardList != null) {
        rewards
          ..clear()
          ..addAll(rewardList);
      }
      final fetchedNotifications = results[4] as List<NotificationItem>?;
      if (fetchedNotifications != null) {
        notifications
          ..clear()
          ..addAll(_withPendingNotificationChanges(firebaseUid, fetchedNotifications));
      }
      final refundList = results[5] as List<RefundRequest>?;
      if (refundList != null) {
        refunds
          ..clear()
          ..addAll(refundList);
      }
      final paymentList = results[6] as List<PaymentTransaction>?;
      if (paymentList != null) {
        payments
          ..clear()
          ..addAll(paymentList);
      }
      final addressList = results[7] as List<CustomerAddress>?;
      if (addressList != null) addresses = addressList;
      final fetchedProfile = results[8] as CustomerProfile?;
      if (fetchedProfile != null) profile = _withPendingProfileChange(firebaseUid, fetchedProfile);

      if (failures == 0) {
        _uid = firebaseUid;
        _error = null;
        _startRealtime(firebaseUid);
        if (CacheStatus.instance.serveCounter == serveMark) lastSyncedAt = DateTime.now();
      } else {
        // Anything that loaded is shown, but the load is NOT complete: the
        // screens' error + retry state applies until it fully succeeds.
        _error = firstFailure ?? AppErrors.from(StateError('load failed'));
      }
    } catch (e) {
      if (generation != _generation) return;
      _error = AppErrors.from(e);
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Re-applies not-yet-synced notification changes on top of freshly read
  /// data, so an offline "mark read"/"delete" doesn't visibly revert just
  /// because the server (or cache) hasn't seen it yet.
  List<NotificationItem> _withPendingNotificationChanges(
      String uid,
      List<NotificationItem> fetched,
      ) {
    final writes = PendingWritesService.instance;
    final deletes = writes.pendingNotificationDeleteIds(uid);
    final reads = writes.pendingNotificationReadIds(uid);
    final markAll = writes.hasPendingMarkAllRead(uid);
    final result = <NotificationItem>[];
    for (final n in fetched) {
      if (deletes.contains(n.id)) continue;
      if (markAll || reads.contains(n.id)) n.read = true;
      result.add(n);
    }
    return result;
  }

  CustomerProfile _withPendingProfileChange(String uid, CustomerProfile fetched) {
    final pending = PendingWritesService.instance.pendingProfileUpdate(uid);
    if (pending == null) return fetched;
    return fetched.copyWith(
      fullName: pending['fullName'] as String?,
      phone: pending['phone'] as String?,
    );
  }

  /// Ensures the given customer's profile row exists (creating it from
  /// their Firebase name/email the first time), and caches it here.
  Future<CustomerProfile> ensureProfile({
    required String firebaseUid,
    required String fallbackName,
    required String fallbackEmail,
  }) async {
    final p = await CustomerProfileRepository.instance.ensureProfile(
      firebaseUid: firebaseUid,
      fallbackName: fallbackName,
      fallbackEmail: fallbackEmail,
    );
    final resolved = _withPendingProfileChange(firebaseUid, p);
    profile = resolved;
    notifyListeners();
    return resolved;
  }

  void updateCachedProfile(CustomerProfile updated) {
    profile = updated;
    notifyListeners();
  }

  /// Lets [SavedAddressesScreen] push its freshly-fetched address list back
  /// in here after an add/edit/delete, instead of triggering a full
  /// `refresh()` re-fetch of every other customer record just to update one.
  void setAddresses(List<CustomerAddress> updated) {
    addresses = updated;
    notifyListeners();
  }

  // ---- Realtime -------------------------------------------------------------

  /// Subscribes to this customer's notifications, orders and payments.
  /// Idempotent for the same customer; switching customers restarts it.
  void _startRealtime(String uid) {
    if (_realtimeUid == uid && _notificationsSub != null) return;
    stopRealtime();
    _realtimeUid = uid;
    final generation = _generation;

    void onError(Object error, StackTrace stack) {
      if (generation != _generation) return;
      if (_realtimePaused) return;
      _realtimePaused = true;
      notifyListeners();
    }

    _notificationsSub = NotificationsRepository.instance.watchAll(uid).listen(
      (items) => _onNotificationsEvent(generation, uid, items),
      onError: onError,
    );
    _ordersSub = OrdersRepository.instance.watchCustomerOrders(uid).listen(
      (rows) => _onOrdersEvent(generation, uid, rows),
      onError: onError,
    );
    _paymentsSub = PaymentsRepository.instance.watchAll(uid).listen(
      (items) => _onPaymentsEvent(generation, items),
      onError: onError,
    );
  }

  /// Cancels every live subscription. Safe to call repeatedly.
  void stopRealtime() {
    _notificationsSub?.cancel();
    _ordersSub?.cancel();
    _paymentsSub?.cancel();
    _notificationsSub = null;
    _ordersSub = null;
    _paymentsSub = null;
    _realtimeUid = null;
    _realtimePaused = false;
    _orderStamps.clear();
    _orderRefreshQueued = false;
  }

  void _onNotificationsEvent(int generation, String uid, List<NotificationItem> items) {
    if (generation != _generation) return;
    _realtimePaused = false;
    notifications
      ..clear()
      ..addAll(_withPendingNotificationChanges(uid, items));
    notifyListeners();
  }

  void _onPaymentsEvent(int generation, List<PaymentTransaction> items) {
    if (generation != _generation) return;
    _realtimePaused = false;
    payments
      ..clear()
      ..addAll(items);
    notifyListeners();
  }

  void _onOrdersEvent(int generation, String uid, List<Map<String, dynamic>> rows) {
    if (generation != _generation) return;
    _realtimePaused = false;
    final local = <String, Order>{for (final o in orders) o.id: o};
    var changed = false;
    for (final row in rows) {
      final id = row['id'] as String;
      final stamp = '${row['status']}|${row['updated_at']}';
      final known = local[id];
      final previousStamp = _orderStamps[id];
      if (known == null ||
          known.status.name != row['status'] ||
          (previousStamp != null && previousStamp != stamp)) {
        changed = true;
      }
      _orderStamps[id] = stamp;
    }
    if (changed) unawaited(_refreshAfterOrderChange(generation, uid));
  }

  /// An order changed on the server: re-read orders and the loyalty records
  /// that an order's completion/cancellation can change. Runs one at a time;
  /// a change that arrives mid-refresh triggers one more pass. A failed pass
  /// keeps the last good data (the reconnect/pull-to-refresh sync recovers).
  Future<void> _refreshAfterOrderChange(int generation, String uid) async {
    if (_loading) {
      // A full load is running (or queued) and will read the new state.
      unawaited(_load(uid));
      return;
    }
    if (_orderRefreshRunning) {
      _orderRefreshQueued = true;
      return;
    }
    _orderRefreshRunning = true;
    try {
      do {
        _orderRefreshQueued = false;
        Future<T?> quiet<T>(Future<T> Function() action) async {
          try {
            return await AppErrors.guard(action, timeout: AppErrors.rpcTimeout);
          } catch (_) {
            return null;
          }
        }

        final results = await Future.wait<Object?>([
          quiet(() => OrdersRepository.instance.fetchOrders(uid)),
          quiet(() => LoyaltyRepository.instance.fetchBalance(uid)),
          quiet(() => LoyaltyRepository.instance.fetchTransactions(uid)),
        ]);
        if (generation != _generation) return;
        final fetchedOrders = results[0] as List<Order>?;
        if (fetchedOrders != null) {
          orders
            ..clear()
            ..addAll(fetchedOrders);
        }
        final balance = results[1] as int?;
        if (balance != null) pointsBalance = balance;
        final txs = results[2] as List<LoyaltyPointTransaction>?;
        if (txs != null) {
          loyaltyTransactions
            ..clear()
            ..addAll(txs);
        }
        notifyListeners();
      } while (_orderRefreshQueued && generation == _generation);
    } finally {
      _orderRefreshRunning = false;
    }
  }

  @override
  void dispose() {
    stopRealtime();
    super.dispose();
  }

  // ---- Server-confirmed additions -----------------------------------------

  /// Adds a refund request the SERVER just created (returned by the
  /// `request_refund` call) to the top of the local list.
  void addRefund(RefundRequest request) {
    refunds.removeWhere((r) => r.id == request.id);
    refunds.insert(0, request);
    notifyListeners();
  }

  /// Replaces the local copy of a payment with the server's latest state.
  void upsertPayment(PaymentTransaction payment) {
    payments.removeWhere((p) => p.orderId == payment.orderId);
    payments.insert(0, payment);
    notifyListeners();
  }

  // ---- Notifications: optimistic locally, durable, honest outcome --------

  /// Marks a notification read. The change is saved on this device
  /// immediately and synced to the server; if the server rejects it the
  /// local state is re-read so the UI never keeps a change the server refused.
  Future<WriteOutcome?> markNotificationRead(String id) async {
    for (final n in notifications) {
      if (n.id == id) n.read = true;
    }
    notifyListeners();
    return _syncNotificationWrite(PendingWriteKind.notificationMarkRead, {'id': id});
  }

  Future<WriteOutcome?> markAllNotificationsRead() async {
    for (final n in notifications) {
      n.read = true;
    }
    notifyListeners();
    return _syncNotificationWrite(PendingWriteKind.notificationMarkAllRead, const {});
  }

  Future<WriteOutcome?> deleteNotification(String id) async {
    notifications.removeWhere((n) => n.id == id);
    notifyListeners();
    return _syncNotificationWrite(PendingWriteKind.notificationDelete, {'id': id});
  }

  Future<WriteOutcome?> _syncNotificationWrite(
      PendingWriteKind kind,
      Map<String, dynamic> payload,
      ) async {
    final uid = _uid ?? _requestedUid;
    if (uid == null) return null;
    final outcome = await PendingWritesService.instance.run(uid, kind, payload);
    if (outcome.kind == WriteOutcomeKind.rejected) {
      unawaited(refresh());
    }
    return outcome;
  }

  /// Wipes the durable per-customer state (unsent writes, unconfirmed
  /// checkout, saved server responses) for [uid]. Called by sign-out AFTER a
  /// best-effort flush while the session is still valid.
  Future<void> prepareForSignOut(String uid) async {
    if (ConnectivityService.instance.isOnline) {
      try {
        await PendingWritesService.instance.flush(uid).timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    await PendingWritesService.instance.clearForUser(uid);
    await CheckoutAttemptStore.instance.reset();
    await LocalCache.instance.clearScope(uid);
  }

  /// Clears every cached customer record — call on sign-out so the next
  /// signed-in account (on a shared device) never sees a previous
  /// customer's data.
  void clear() {
    stopRealtime();
    _generation++;
    _uid = null;
    _requestedUid = null;
    _fallbackName = null;
    _fallbackEmail = null;
    _inFlight = null;
    _reloadQueued = false;
    _loading = false;
    _error = null;
    pointsBalance = 0;
    earnPesosPerPoint = 50;
    profile = null;
    addresses = [];
    lastSyncedAt = null;
    orders.clear();
    loyaltyTransactions.clear();
    rewards.clear();
    notifications.clear();
    refunds.clear();
    payments.clear();
    CacheStatus.instance.reset();
    notifyListeners();
  }
}
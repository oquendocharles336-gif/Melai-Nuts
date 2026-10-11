import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/catalog_store.dart';
import '../../data/models/delivery.dart';
import '../../data/models/inventory_batch.dart';
import '../../data/models/inventory_item.dart';
import '../../data/models/staff_models.dart';
import '../../data/repositories/branch_repository.dart';
import '../../data/repositories/delivery_repository.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/staff_repository.dart';
import '../utils/app_error.dart';
import 'staff_session_store.dart';
import 'supabase_service.dart';

/// Loading status of one section of staff data.
class LoadState {
  bool loading = false;
  bool loaded = false;
  Object? error;

  /// A refresh was requested while one was running; run once more after.
  bool rerun = false;

  /// True until the first load has finished (successfully or not) — lets a
  /// screen show a spinner instead of flashing an "empty" state.
  bool get busy => loading || (!loaded && error == null);
}

/// The signed-in staff member's session and live working data: profile, the
/// branch they are working in, dashboard numbers, inventory, orders, transfers
/// and notifications.
///
/// Everything here is read from the database (which enforces who may see what);
/// nothing is stored on the device. Realtime subscriptions refresh it when
/// orders, stock, transfers or notifications change.
///
/// Staff always work in their assigned branch. An owner has no assigned branch
/// and picks the branch to view with [setOwnerBranch].
class StaffStore extends ChangeNotifier {
  StaffStore._();
  static final StaffStore instance = StaffStore._();

  final StaffRepository _repo = StaffRepository.instance;
  final DeliveryRepository _deliveryRepo = DeliveryRepository.instance;

  int _generation = 0;
  Timer? _debounce;
  RealtimeChannel? _channel;
  String? _channelKey;

  // ---- Session -------------------------------------------------------------
  StaffProfile? profile;
  final LoadState profileState = LoadState();
  String? _ownerBranchId;

  bool get isOwner => profile?.isOwner ?? false;
  bool get canManageInventory => profile?.canManageInventory ?? false;
  bool get canReviewRefunds => profile?.canReviewRefunds ?? false;

  String? get activeBranchId => profile == null
      ? null
      : (profile!.isOwner ? _ownerBranchId : profile!.branchId);

  String get activeBranchName {
    final id = activeBranchId;
    if (id == null) return '';
    final fromDashboard = dashboard?.branch;
    if (fromDashboard != null && fromDashboard.id == id) return fromDashboard.name;
    if (!isOwner) return profile?.branchName ?? '';
    for (final b in kBranches) {
      if (b.id == id) return b.name;
    }
    return '';
  }

  // ---- Data ------------------------------------------------------------------
  StaffDashboard? dashboard;
  final LoadState dashboardState = LoadState();

  List<InventoryItem> inventoryItems = const [];
  List<InventoryBatch> batches = const [];
  final LoadState inventoryState = LoadState();

  List<StaffOrder> orders = const [];
  final LoadState ordersState = LoadState();

  /// Where customers pinned this branch's delivery orders, by order id
  /// (`staff_order_delivery_pins`). Loaded after the orders, best effort: an
  /// order missing here has no pin, unless [deliveryPinsLoaded] is false
  /// (older server / not loaded yet), in which case nothing is claimed.
  Map<String, OrderDeliveryPin> deliveryPins = const {};
  bool deliveryPinsLoaded = false;

  List<StockTransfer> transfers = const [];
  final LoadState transfersState = LoadState();

  List<StaffNotification> notifications = const [];
  final LoadState notificationsState = LoadState();

  List<StaffRefund> refunds = const [];
  final LoadState refundsState = LoadState();

  List<Delivery> deliveries = const [];
  final LoadState deliveriesState = LoadState();

  int get unreadNotifications => notifications.where((n) => !n.read).length;

  InventoryItem? itemByVariant(String variantId) {
    for (final i in inventoryItems) {
      if (i.variantId == variantId) return i;
    }
    return null;
  }

  // ---- Lifecycle ----------------------------------------------------------------

  /// Loads the profile and then everything else. Safe to call from any
  /// staff screen: it does nothing if a session is already loaded/loading.
  Future<void> ensureStarted() async {
    if (profile != null || profileState.loading) return;
    await start();
  }

  Future<void> start() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    // A session left over from another account is wiped first (this also
    // resets this store through the reset hook), so the generation captured
    // below is the one that stays valid for the whole load.
    final heldBy = StaffSessionStore.instance.ownerUid;
    if (heldBy != null && heldBy != uid) StaffSessionStore.instance.clear();
    final gen = _generation;
    profileState.loading = true;
    profileState.error = null;
    _notifySoon();
    try {
      // Identity comes from the one identity-bound session (Firebase UID ->
      // staff_members row). It is confirmed by the server for exactly the
      // account that is signed in, or this throws and nothing is shown.
      if (uid == null) {
        throw const AppError(AppErrorKind.authExpired, 'Please sign in again.');
      }
      final status = await StaffSessionStore.instance.loadForStaff(uid);
      if (gen != _generation) return;
      final ctx = StaffSessionStore.instance.context;
      if (status != StaffSessionStatus.ready || ctx == null) {
        throw StaffSessionStore.instance.accessError ?? AppErrors.staffNotProvisioned();
      }
      final p = ctx.profile;
      profile = p;
      profileState.loaded = true;
      if (p.isOwner) {
        // Owners pick a branch: default to the first real branch.
        await BranchRepository.instance.loadBranches();
        if (gen != _generation) return;
        final list = kBranches;
        _ownerBranchId ??= list.isEmpty ? null : list.first.id;
      }
    } catch (e) {
      if (gen != _generation) return;
      profile = null;
      profileState.error = e;
    } finally {
      if (gen == _generation) {
        profileState.loading = false;
        notifyListeners();
      }
    }
    if (gen != _generation || profile == null) return;
    _restartRealtime();
    unawaited(ProductsRepository.instance.loadCatalog());
    await refreshAll();
  }

  /// Re-reads every section (pull-to-refresh, reconnect, branch change).
  Future<void> refreshAll() async {
    if (profile == null) return;
    await Future.wait([
      refreshDashboard(),
      refreshInventory(),
      refreshOrders(),
      refreshTransfers(),
      refreshNotifications(),
      if (canReviewRefunds) refreshRefunds(),
      if (deliveriesState.loaded) refreshDeliveries(),
    ]);
  }

  /// Called after a local write and by realtime events.
  Future<void> refreshLive() => refreshAll();

  Future<void> setOwnerBranch(String branchId) async {
    if (!isOwner || _ownerBranchId == branchId) return;
    _ownerBranchId = branchId;
    dashboard = null;
    inventoryItems = const [];
    batches = const [];
    orders = const [];
    deliveryPins = const {};
    deliveryPinsLoaded = false;
    transfers = const [];
    refunds = const [];
    deliveries = const [];
    dashboardState.loaded = false;
    inventoryState.loaded = false;
    ordersState.loaded = false;
    transfersState.loaded = false;
    refundsState.loaded = false;
    deliveriesState.loaded = false;
    notifyListeners();
    _restartRealtime();
    await refreshAll();
  }

  /// Wipes everything held in memory (sign-out).
  void clear() {
    _generation++;
    _debounce?.cancel();
    _stopRealtime();
    profile = null;
    _ownerBranchId = null;
    dashboard = null;
    inventoryItems = const [];
    batches = const [];
    orders = const [];
    deliveryPins = const {};
    deliveryPinsLoaded = false;
    transfers = const [];
    notifications = const [];
    refunds = const [];
    deliveries = const [];
    for (final s in [
      profileState,
      dashboardState,
      inventoryState,
      ordersState,
      transfersState,
      notificationsState,
      refundsState,
      deliveriesState,
    ]) {
      s
        ..loading = false
        ..loaded = false
        ..rerun = false
        ..error = null;
    }
    notifyListeners();
  }

  // ---- Section loaders -------------------------------------------------------------

  Future<void> _load(LoadState state, Future<void> Function() body) async {
    final gen = _generation;
    if (state.loading) {
      state.rerun = true;
      return;
    }
    state.loading = true;
    _notifySoon();
    try {
      await body();
      if (gen != _generation) return;
      state.error = null;
      state.loaded = true;
    } catch (e) {
      if (gen != _generation) return;
      state.error = AppErrors.from(e);
    } finally {
      if (gen == _generation) {
        state.loading = false;
        notifyListeners();
        if (state.rerun) {
          state.rerun = false;
          unawaited(_load(state, body));
        }
      }
    }
  }

  Future<void> refreshDashboard() => _load(dashboardState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final d = await _repo.getDashboard(branch);
        if (branch == activeBranchId) dashboard = d;
      });

  Future<void> refreshInventory() => _load(inventoryState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final s = await _repo.getInventory(branch);
        if (branch == activeBranchId) {
          inventoryItems = s.items;
          batches = s.batches;
        }
      });

  Future<void> refreshOrders() => _load(ordersState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final rows = await _repo.listOrders(branchId: branch, limit: 150);
        if (branch == activeBranchId) {
          orders = rows;
          unawaited(_loadDeliveryPins(branch, rows));
        }
      });

  Future<void> _loadDeliveryPins(String branch, List<StaffOrder> rows) async {
    final gen = _generation;
    final ids = [for (final o in rows) if (o.isDelivery) o.id];
    try {
      final pins = await _deliveryRepo.orderDeliveryPins(ids);
      if (gen != _generation || branch != activeBranchId) return;
      deliveryPins = pins;
      deliveryPinsLoaded = true;
      notifyListeners();
    } catch (_) {
      // Older server without staff_order_delivery_pins, or offline: the order
      // screens simply show no pin information (never a guessed one).
    }
  }

  Future<void> refreshTransfers() => _load(transfersState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final rows = await _repo.listTransfers(branch);
        if (branch == activeBranchId) transfers = rows;
      });

  Future<void> refreshNotifications() => _load(notificationsState, () async {
        notifications = await _repo.fetchNotifications();
      });

  Future<void> refreshRefunds() => _load(refundsState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final rows = await _repo.listRefunds(branch);
        if (branch == activeBranchId) refunds = rows;
      });

  Future<void> refreshDeliveries() => _load(deliveriesState, () async {
        final branch = activeBranchId;
        if (branch == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final rows = await _deliveryRepo.getDeliveries(branch);
        if (branch == activeBranchId) deliveries = rows;
      });

  /// Merges a freshly-written [delivery] (from a create/update/cancel call)
  /// into the cached list immediately, so every screen reading
  /// [StaffStore.instance.deliveries] sees it without waiting for the next
  /// [refreshDeliveries]. Also kicks off a real refresh in the background to
  /// stay in sync with anything else that changed server-side.
  void applyDelivery(Delivery delivery) {
    final idx = deliveries.indexWhere((d) => d.id == delivery.id);
    deliveries = idx == -1
        ? [delivery, ...deliveries]
        : [for (final d in deliveries) d.id == delivery.id ? delivery : d];
    notifyListeners();
    unawaited(refreshDeliveries());
  }

  // ---- Notifications --------------------------------------------------------------

  Future<void> markNotificationRead(String id) async {
    notifications = [for (final n in notifications) n.id == id ? n.asRead() : n];
    notifyListeners();
    try {
      await _repo.markNotificationRead(id);
    } catch (_) {
      unawaited(refreshNotifications()); // the server refused: show the truth
    }
  }

  Future<void> markAllNotificationsRead() async {
    notifications = [for (final n in notifications) n.asRead()];
    notifyListeners();
    try {
      await _repo.markAllNotificationsRead();
    } catch (_) {
      unawaited(refreshNotifications());
    }
  }

  Future<void> deleteNotification(String id) async {
    notifications = notifications.where((n) => n.id != id).toList();
    notifyListeners();
    try {
      await _repo.deleteNotification(id);
    } catch (_) {
      unawaited(refreshNotifications());
    }
  }

  // ---- Realtime -------------------------------------------------------------------------

  void _restartRealtime() {
    final p = profile;
    final branch = activeBranchId;
    if (p == null || branch == null) return;
    final key = '${p.uid}|$branch';
    if (_channelKey == key && _channel != null) return;
    _stopRealtime();
    _channelKey = key;

    PostgresChangeFilter branchFilter() => PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'branch_id',
          value: branch,
        );

    var channel = SupabaseService.instance.client.channel('staff-live-$key');
    for (final table in const ['orders', 'branch_inventory', 'inventory_batches']) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: branchFilter(),
        callback: (_) => _scheduleRefresh(),
      );
    }
    // Transfers involve two branches and refunds hang off orders, so these
    // are unfiltered; row-level security still limits what is delivered.
    // (`deliveries`/`delivery_stops` have no SELECT policy at all — direct
    // table access is denied by design, everything goes through the
    // staff_* delivery RPCs — so they cannot be watched over realtime;
    // delivery screens refresh explicitly instead, the same way refunds do.)
    for (final table in const ['stock_transfers', 'refund_requests']) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _scheduleRefresh(),
      );
    }
    channel = channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'staff_notifications',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'recipient_uid',
        value: p.uid,
      ),
      callback: (_) => _scheduleRefresh(),
    );
    channel.subscribe();
    _channel = channel;
  }

  void _stopRealtime() {
    final ch = _channel;
    _channel = null;
    _channelKey = null;
    if (ch != null) {
      try {
        unawaited(SupabaseService.instance.client.removeChannel(ch));
      } catch (_) {}
    }
  }

  /// A burst of changes (a sale touches orders, stock and batches) causes one
  /// refresh, not many.
  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () {
      if (profile != null) unawaited(refreshAll());
    });
  }

  /// notifyListeners can be reached from initState (mid-build); defer it.
  void _notifySoon() => scheduleMicrotask(notifyListeners);
}

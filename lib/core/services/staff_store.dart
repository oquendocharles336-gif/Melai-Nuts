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
import 'staff_inventory_overlay.dart';
import 'staff_offline_store.dart';
import 'staff_session_store.dart';
import 'supabase_service.dart';
import 'sync_service.dart';

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
/// Everything here is read from the database (which enforces who may see what).
/// The last answers (inventory, dashboard, orders with their full e-receipt
/// data) are kept on the device ([StaffOfflineStore]) so every staff screen
/// keeps working offline from that copy; changes made offline (products,
/// received / adjusted stock, sales) are shown on top of it, marked
/// "Pending sync", until the server has them. Realtime subscriptions refresh
/// it when orders, stock, transfers or notifications change.
///
/// Staff always work in their assigned branch. An owner has no assigned branch
/// and picks the branch to view with [setOwnerBranch].
class StaffStore extends ChangeNotifier {
  StaffStore._() {
    // A change saved / synced on this device re-shows the data at once.
    _offline.addListener(_onLocalChange);
    // A queued change reached the server: re-read the server copy (debounced).
    SyncService.instance.addListener(_onSyncCounts);
  }
  static final StaffStore instance = StaffStore._();

  final StaffRepository _repo = StaffRepository.instance;
  final DeliveryRepository _deliveryRepo = DeliveryRepository.instance;
  final StaffOfflineStore _offline = StaffOfflineStore.instance;

  /// The signed-in staff member's UID: the scope of everything kept on the device.
  String? get _scope => profile?.uid;

  // Last server copies (live, or read back from the device while offline).
  StaffInventorySnapshot? _baseInventory;
  DateTime? _baseInventoryAt;
  String? _baseInventoryBranch;
  List<StaffOrder>? _baseOrders;
  String? _baseOrdersBranch;
  List<StaffNotification> _serverNotifications = const [];
  int _lastPending = 0;
  Timer? _localDebounce;

  /// True while a section is shown from the copy saved on this device
  /// because the server could not be reached.
  bool inventoryFromSavedCopy = false;
  bool ordersFromSavedCopy = false;
  bool dashboardFromSavedCopy = false;

  int _generation = 0;
  Timer? _debounce;
  RealtimeChannel? _channel;
  String? _channelKey;

  // ---- Session -------------------------------------------------------------
  StaffProfile? profile;
  final LoadState profileState = LoadState();
  String? _ownerBranchId;

  /// Saves a new profile picture for the signed-in staff member.
  Future<void> setProfilePhoto(Uint8List bytes, {required String contentType}) async {
    final current = profile;
    if (current == null) return;
    final path = await StaffRepository.instance.uploadProfilePhoto(
      uid: current.uid,
      bytes: bytes,
      contentType: contentType,
    );
    final old = current.profileImage;
    profile = current.withProfileImage(path);
    notifyListeners();
    // The session (and its offline copy) was loaded before the change: update
    // it too, or the next rebuild from it shows the initials again.
    await StaffSessionStore.instance.applyOwnProfileImage(current.uid, path);
    if (old != null && old.isNotEmpty) unawaited(StaffRepository.instance.deleteProfilePhotoFile(old));
  }

  /// Removes the signed-in staff member's profile picture.
  Future<void> removeProfilePhoto() async {
    final current = profile;
    final old = current?.profileImage;
    if (current == null || old == null || old.isEmpty) return;
    await StaffRepository.instance.clearProfilePhoto();
    profile = current.withProfileImage(null);
    notifyListeners();
    await StaffSessionStore.instance.applyOwnProfileImage(current.uid, null);
    unawaited(StaffRepository.instance.deleteProfilePhotoFile(old));
  }

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

  /// Products created / edited on this device that the server does not have
  /// yet (shown with "Pending sync" in the product list).
  List<PendingProduct> pendingProducts = const [];
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
    unawaited(_offline.tidy(profile!.uid));
    _restartRealtime();
    unawaited(ProductsRepository.instance.loadCatalog());
    await refreshAll();
    unawaited(_checkExpiringBatches(gen));
  }

  /// Makes sure staff are told about batches about to expire, even when the
  /// server's daily job is not scheduled. Never blocks or fails the portal.
  Future<void> _checkExpiringBatches(int gen) async {
    final branch = activeBranchId;
    if (branch == null || !canManageInventory) return;
    try {
      final added = await _repo.checkExpiringBatches(branch);
      if (added > 0 && gen == _generation) await refreshNotifications();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:expiry_check');
    }
  }

  /// Re-reads every section (pull-to-refresh, reconnect, branch change).
  Future<void> refreshAll() async {
    if (profile == null) return;
    await Future.wait([
      refreshDashboard(),
      refreshInventory(),
      refreshOrders(),
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
    _baseInventory = null;
    _baseOrders = null;
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
    // Sign-out / account change: the saved copies of this account's branch
    // data are erased (unsent changes stay queued for this account only).
    final signedOut = profile?.uid;
    if (signedOut != null) unawaited(_offline.clearCopiesForSignOut(signedOut));
    _generation++;
    _debounce?.cancel();
    _localDebounce?.cancel();
    _baseInventory = null;
    _baseInventoryAt = null;
    _baseInventoryBranch = null;
    _baseOrders = null;
    _baseOrdersBranch = null;
    _serverNotifications = const [];
    pendingProducts = const [];
    inventoryFromSavedCopy = false;
    ordersFromSavedCopy = false;
    dashboardFromSavedCopy = false;
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

  /// The copy of [kind] saved on this device, used when [error] is a
  /// connectivity failure. Anything else (or no saved copy) is rethrown.
  Future<({Map<String, dynamic> json, DateTime savedAt})> _savedSnapshot(
      String scope, String branch, String kind, Object error) async {
    final mapped = AppErrors.from(error);
    if (!mapped.isConnectivity) throw mapped;
    final saved = await _offline.snapshot(scope, branch, kind);
    if (saved == null) throw mapped;
    return saved;
  }

  /// Saving the offline copy is best effort: it never fails a refresh.
  Future<void> _quietly(Future<void> Function() save, String where) async {
    try {
      await save();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:$where');
    }
  }

  Future<void> refreshDashboard() => _load(dashboardState, () async {
        final branch = activeBranchId;
        final scope = _scope;
        if (branch == null || scope == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final started = DateTime.now();
        Map<String, dynamic> raw;
        var fromCopy = false;
        try {
          raw = await _repo.fetchDashboardJson(branch);
          unawaited(_quietly(() => _offline.saveSnapshot(scope, branch, 'dashboard', raw, fetchedAt: started), 'dashboard_copy'));
        } catch (e) {
          raw = (await _savedSnapshot(scope, branch, 'dashboard', e)).json;
          fromCopy = true;
        }
        if (branch == activeBranchId) {
          dashboard = StaffDashboard.fromJson(raw);
          dashboardFromSavedCopy = fromCopy;
        }
      });

  Future<void> refreshInventory() => _load(inventoryState, () async {
        final branch = activeBranchId;
        final scope = _scope;
        if (branch == null || scope == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        final started = DateTime.now();
        StaffInventorySnapshot base;
        DateTime baseAt;
        var fromCopy = false;
        try {
          final raw = await _repo.fetchInventoryJson(branch);
          base = _repo.parseInventory(raw);
          baseAt = started;
          unawaited(_quietly(() => _offline.saveSnapshot(scope, branch, 'inventory', raw, fetchedAt: started), 'inventory_copy'));
        } catch (e) {
          final saved = await _savedSnapshot(scope, branch, 'inventory', e);
          base = _repo.parseInventory(saved.json);
          baseAt = saved.savedAt;
          fromCopy = true;
        }
        if (branch != activeBranchId) return;
        _baseInventory = base;
        _baseInventoryAt = baseAt;
        _baseInventoryBranch = branch;
        inventoryFromSavedCopy = fromCopy;
        // Until the overlay is computed, show the server copy as it is.
        inventoryItems = base.items;
        batches = base.batches;
        await _applyInventoryOverlay();
      });

  /// Shows this device's not-yet-counted changes on top of the server copy.
  Future<void> _applyInventoryOverlay() async {
    final scope = _scope;
    if (scope == null) return;
    final products = await _offline.pendingProducts(scope);
    if (scope != _scope) return;
    pendingProducts = products;
    final base = _baseInventory;
    final at = _baseInventoryAt;
    final branch = _baseInventoryBranch;
    if (base == null || at == null || branch == null || branch != activeBranchId) return;
    final movements = await _offline.unreconciledMovements(scope, branch, at);
    if (!identical(base, _baseInventory)) return; // a newer copy arrived meanwhile
    final shown = StaffInventoryOverlay.apply(
      base: base,
      movements: movements,
      pendingProducts: products,
      branchName: activeBranchName,
    );
    inventoryItems = shown.items;
    batches = shown.batches;
  }

  Future<void> refreshOrders() => _load(ordersState, () async {
        final branch = activeBranchId;
        final scope = _scope;
        if (branch == null || scope == null) throw const AppError(AppErrorKind.notFound, 'Please choose a branch first.');
        List<StaffOrder> server;
        var fromCopy = false;
        try {
          final rows = await _repo.listOrderRows(branchId: branch, limit: 150);
          server = rows.map(StaffOrder.fromJson).toList();
          // Full receipt data of every fetched order, for offline e-receipts.
          unawaited(_quietly(() => _offline.saveServerReceipts(scope, branch, rows), 'receipts_copy'));
          unawaited(_offline.dropReconciledReceipts(scope, {for (final o in server) o.id}));
        } catch (e) {
          final mapped = AppErrors.from(e);
          if (!mapped.isConnectivity) throw mapped;
          final saved = await _offline.receipts(scope, branch, limit: 150);
          if (saved.isEmpty) throw mapped;
          server = [for (final r in saved) if (!r.isLocal) r.toOrder()];
          fromCopy = true;
        }
        if (branch != activeBranchId) return;
        _baseOrders = server;
        _baseOrdersBranch = branch;
        ordersFromSavedCopy = fromCopy;
        orders = server;
        await _applyOrdersOverlay();
        if (!fromCopy) unawaited(_loadDeliveryPins(branch, server));
      });

  /// Adds the sales rung up on this device (with locally generated
  /// e-receipts) to the server's orders until the server has them.
  Future<void> _applyOrdersOverlay() async {
    final base = _baseOrders;
    final branch = _baseOrdersBranch;
    final scope = _scope;
    if (base == null || branch == null || scope == null || branch != activeBranchId) return;
    final local = await _offline.localReceipts(scope, branch);
    if (!identical(base, _baseOrders)) return;
    final serverIds = {for (final o in base) o.id};
    final extra = [
      for (final r in local)
        if (r.serverOrderId == null || !serverIds.contains(r.serverOrderId)) r.toOrder(),
    ];
    orders = extra.isEmpty ? base : ([...extra, ...base]..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  /// One order with its receipt kept on the device (POS receipt screen).
  /// Offline, the saved copy is returned instead.
  Future<StaffOrder?> fetchOrderWithReceipt(String orderId) async {
    final branch = activeBranchId;
    final scope = _scope;
    try {
      final rows = await _repo.listOrderRows(branchId: branch, orderId: orderId, limit: 1);
      if (rows.isEmpty) return null;
      if (scope != null && branch != null) {
        unawaited(_quietly(() => _offline.saveServerReceipts(scope, branch, rows), 'receipt_copy'));
      }
      return StaffOrder.fromJson(rows.first);
    } catch (e) {
      if (scope == null || !AppErrors.from(e).isConnectivity) rethrow;
      final saved = await _offline.receipt(scope, orderId);
      if (saved == null) rethrow;
      return saved.toOrder();
    }
  }

  /// The e-receipt of [orderId] as stored on this device (works offline).
  Future<StaffOrder?> storedReceipt(String orderId) async {
    final scope = _scope;
    if (scope == null) return null;
    return (await _offline.receipt(scope, orderId))?.toOrder();
  }

  void _onLocalChange() {
    if (profile == null) return;
    _localDebounce?.cancel();
    _localDebounce = Timer(const Duration(milliseconds: 150), () async {
      final gen = _generation;
      await Future.wait([_applyInventoryOverlay(), _applyOrdersOverlay(), _applyNotifications()]);
      if (gen == _generation) notifyListeners();
    });
  }

  void _onSyncCounts() {
    final pending = SyncService.instance.pendingCount;
    final sent = pending < _lastPending;
    _lastPending = pending;
    if (sent && profile != null) _scheduleRefresh();
  }

  Future<void> _loadDeliveryPins(String branch, List<StaffOrder> rows) async {
    final gen = _generation;
    final ids = [for (final o in rows) if (o.isDelivery) o.id];
    try {
      final pins = await _deliveryRepo.orderDeliveryPins(ids);
      if (gen != _generation || branch != activeBranchId) return;
      deliveryPins = pins;
      deliveryPinsLoaded = true;
      notifyListeners();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:321');
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
        try {
          // Offline, the read cache answers with the last saved list.
          _serverNotifications = await _repo.fetchNotifications();
        } catch (e) {
          final mapped = AppErrors.from(e);
          if (!mapped.isConnectivity) throw mapped;
          // Nothing saved yet: keep what is shown; local notices still appear.
        }
        await _applyNotifications();
      });

  /// Server notifications plus the ones raised on this device (connection,
  /// sync, expired stock), newest first.
  Future<void> _applyNotifications() async {
    final scope = _scope;
    final local = scope == null ? const <StaffNotification>[] : await _offline.notifications(scope);
    final all = [...local, ..._serverNotifications]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifications = all;
  }

  /// Adds a notification raised on this device to the list (and the badge).
  Future<void> addLocalNotification(StaffNotification n) async {
    final scope = _scope;
    if (scope == null) return;
    await _offline.putNotification(scope, n);
    await _applyNotifications();
    notifyListeners();
  }

  static bool _isLocal(String id) => id.startsWith('local:');

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
    _serverNotifications = [for (final n in _serverNotifications) n.id == id ? n.asRead() : n];
    notifyListeners();
    final scope = _scope;
    if (_isLocal(id)) {
      if (scope != null) await _offline.markNotificationsRead(scope, id: id);
      return;
    }
    try {
      await _repo.markNotificationRead(id);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:373');
      unawaited(refreshNotifications()); // the server refused: show the truth
    }
  }

  Future<void> markAllNotificationsRead() async {
    notifications = [for (final n in notifications) n.asRead()];
    _serverNotifications = [for (final n in _serverNotifications) n.asRead()];
    notifyListeners();
    final scope = _scope;
    if (scope != null) unawaited(_offline.markNotificationsRead(scope));
    try {
      await _repo.markAllNotificationsRead();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:383');
      unawaited(refreshNotifications());
    }
  }

  Future<void> deleteNotification(String id) async {
    notifications = notifications.where((n) => n.id != id).toList();
    _serverNotifications = _serverNotifications.where((n) => n.id != id).toList();
    notifyListeners();
    final scope = _scope;
    if (_isLocal(id)) {
      if (scope != null) await _offline.deleteNotification(scope, id);
      return;
    }
    try {
      await _repo.deleteNotification(id);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_store:393');
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
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'staff_store:461');
      }
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

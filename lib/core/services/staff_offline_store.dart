import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqlite_api.dart';

import '../../data/models/staff_models.dart';
import '../utils/app_error.dart';
import 'sqlite_service.dart';

/// Where a change made on this device stands with the server.
enum LocalSyncState { pending, synced, failed }

LocalSyncState _parseState(Object? v) {
  for (final s in LocalSyncState.values) {
    if (s.name == v) return s;
  }
  return LocalSyncState.pending;
}

/// A stock change made on this device (receive or adjust). Shown on top of the
/// last server copy until the server has it, and sent as the SAME change
/// (same id = idempotency key) by the sync queue.
class LocalMovement {
  final String id;
  final String branchId;
  final String productId;
  final String variantId;
  final String? batchId;
  final String? batchCode;
  final String movementType; // receive | adjust
  final int quantityChange;
  final bool assignExisting;
  final String? reason;
  final String? note;
  final DateTime? receivedDate;
  final DateTime? expirationDate;
  final int? restockThreshold;
  final String staffUid;
  final DateTime createdAt;
  final LocalSyncState syncState;
  final String? lastError;
  final DateTime? syncedAt;

  const LocalMovement({
    required this.id,
    required this.branchId,
    required this.productId,
    required this.variantId,
    required this.movementType,
    required this.quantityChange,
    required this.staffUid,
    required this.createdAt,
    this.batchId,
    this.batchCode,
    this.assignExisting = false,
    this.reason,
    this.note,
    this.receivedDate,
    this.expirationDate,
    this.restockThreshold,
    this.syncState = LocalSyncState.pending,
    this.lastError,
    this.syncedAt,
  });

  bool get isReceive => movementType == 'receive';

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, Object?> toRow(String scope) => {
    'id': id,
    'scope': scope,
    'branch_id': branchId,
    'product_id': productId,
    'variant_id': variantId,
    'batch_id': batchId,
    'batch_code': batchCode,
    'movement_type': movementType,
    'quantity_change': quantityChange,
    'assign_existing': assignExisting ? 1 : 0,
    'reason': reason,
    'note': note,
    'received_date': receivedDate == null ? null : _date(receivedDate!),
    'expiration_date': expirationDate == null ? null : _date(expirationDate!),
    'restock_threshold': restockThreshold,
    'staff_uid': staffUid,
    'created_at': createdAt.millisecondsSinceEpoch,
    'sync_status': syncState.name,
    'last_error': lastError,
    'synced_at': syncedAt?.millisecondsSinceEpoch,
  };

  factory LocalMovement.fromRow(Map<String, Object?> r) {
    DateTime? day(Object? v) => v == null ? null : DateTime.parse(v as String);
    final synced = r['synced_at'] as int?;
    return LocalMovement(
      id: r['id'] as String,
      branchId: r['branch_id'] as String,
      productId: r['product_id'] as String,
      variantId: r['variant_id'] as String,
      batchId: r['batch_id'] as String?,
      batchCode: r['batch_code'] as String?,
      movementType: r['movement_type'] as String,
      quantityChange: (r['quantity_change'] as int?) ?? 0,
      assignExisting: (r['assign_existing'] as int?) == 1,
      reason: r['reason'] as String?,
      note: r['note'] as String?,
      receivedDate: day(r['received_date']),
      expirationDate: day(r['expiration_date']),
      restockThreshold: r['restock_threshold'] as int?,
      staffUid: r['staff_uid'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      syncState: _parseState(r['sync_status']),
      lastError: r['last_error'] as String?,
      syncedAt: synced == null ? null : DateTime.fromMillisecondsSinceEpoch(synced),
    );
  }
}

/// A product created ([operation] `create`) or edited (`update`) on this
/// device that the server does not have yet.
class PendingProduct {
  final String id;
  final String operation;
  final String localOperationId;

  /// create: {variant_id, name, description, category_id, price, cost_price,
  /// is_active, branch_ids}; update: the full `staff_save_product` arguments.
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final LocalSyncState syncState;
  final String? lastError;

  const PendingProduct({
    required this.id,
    required this.operation,
    required this.localOperationId,
    required this.data,
    required this.createdAt,
    this.syncState = LocalSyncState.pending,
    this.lastError,
  });

  bool get isCreate => operation == 'create';
  String get name => (data['name'] as String?) ?? '';
  String get variantId => (data['variant_id'] as String?) ?? '';
  String? get categoryId => data['category_id'] as String?;
  double get price => (data['price'] as num?)?.toDouble() ?? 0;
  double? get costPrice => (data['cost_price'] as num?)?.toDouble();
  bool get isActive => (data['is_active'] as bool?) ?? true;
  List<String> get branchIds => ((data['branch_ids'] as List?) ?? const []).map((e) => '$e').toList();

  factory PendingProduct.fromRow(Map<String, Object?> r) => PendingProduct(
    id: r['id'] as String,
    operation: r['operation'] as String,
    localOperationId: r['local_operation_id'] as String,
    data: Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map),
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    syncState: _parseState(r['sync_status']),
    lastError: r['last_error'] as String?,
  );
}

/// One order's e-receipt as stored on the device.
class StoredReceipt {
  final String orderId;
  final Map<String, dynamic> json;
  final DateTime createdAt;
  final LocalSyncState syncState;
  final String? localOperationId;
  final String? serverOrderId;
  final String? lastError;

  const StoredReceipt({
    required this.orderId,
    required this.json,
    required this.createdAt,
    required this.syncState,
    this.localOperationId,
    this.serverOrderId,
    this.lastError,
  });

  /// Made on this device for an offline sale (not a server order).
  bool get isLocal => localOperationId != null;

  /// The order as the staff screens show it. A local receipt carries the
  /// "Pending sync" flag until the server has accepted the sale.
  StaffOrder toOrder() => StaffOrder.fromJson({
    ...json,
    '_pending_sync': isLocal && syncState != LocalSyncState.synced,
    if (syncState == LocalSyncState.failed) '_sync_error': lastError ?? 'The server refused this sale.',
  });

  factory StoredReceipt.fromRow(Map<String, Object?> r) => StoredReceipt(
    orderId: r['order_id'] as String,
    json: Map<String, dynamic>.from(jsonDecode(r['json'] as String) as Map),
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    syncState: _parseState(r['sync_status']),
    localOperationId: r['local_operation_id'] as String?,
    serverOrderId: r['server_order_id'] as String?,
    lastError: r['last_error'] as String?,
  );
}

/// The staff side's offline working copy in SQLite (schema version 3, see
/// [SqliteService]): the last server answers, e-receipts, stock movements and
/// products made on this device, expiry-alert bookkeeping and local
/// notifications. Every row belongs to one staff Firebase UID ([scope]).
///
/// It is a cache plus a record of what is waiting to sync — never an
/// authority. Listeners are told whenever something changes, so screens
/// showing "Pending sync" update the moment a change syncs.
class StaffOfflineStore extends ChangeNotifier {
  StaffOfflineStore({Future<Database> Function()? database, DateTime Function()? now})
      : _database = database ?? SqliteService.instance.open,
        _now = now ?? DateTime.now;

  static final StaffOfflineStore instance = StaffOfflineStore();

  final Future<Database> Function() _database;
  final DateTime Function() _now;

  /// Server orders kept per branch for offline receipts (newest first).
  static const int maxStoredReceipts = 300;

  /// Synced movements / receipts older than this are tidied away.
  static const Duration keepSyncedFor = Duration(days: 14);

  Future<T> _guard<T>(Future<T> Function(Database db) action) async {
    try {
      return await action(await _database());
    } catch (e) {
      if (e is AppError) rethrow;
      throw AppErrors.from(e);
    }
  }

  /// Reads never break a screen: no SQLite (web) or a read error = nothing saved.
  Future<T> _read<T>(T fallback, Future<T> Function(Database db) action) async {
    try {
      return await action(await _database());
    } catch (e) {
      if (kDebugMode) debugPrint('StaffOfflineStore read failed: ${e.runtimeType}');
      return fallback;
    }
  }

  /// Housekeeping that must never break a screen (errors are only logged).
  Future<void> _quiet(Future<void> Function(Database db) action) async {
    try {
      await action(await _database());
    } catch (e) {
      if (kDebugMode) debugPrint('StaffOfflineStore housekeeping failed: ${e.runtimeType}');
    }
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

  // ---- Snapshots (inventory / dashboard) -----------------------------------

  Future<void> saveSnapshot(String scope, String branchId, String kind, Map<String, dynamic> json,
      {required DateTime fetchedAt}) {
    return _guard((db) async {
      await db.insert(
        'staff_snapshots',
        {
          'scope': scope,
          'branch_id': branchId,
          'kind': kind,
          'json': jsonEncode(json),
          'saved_at': fetchedAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<({Map<String, dynamic> json, DateTime savedAt})?> snapshot(String scope, String branchId, String kind) {
    return _read(null, (db) async {
      final rows = await db.query(
        'staff_snapshots',
        where: 'scope = ? AND branch_id = ? AND kind = ?',
        whereArgs: [scope, branchId, kind],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return (
      json: Map<String, dynamic>.from(jsonDecode(rows.first['json'] as String) as Map),
      savedAt: DateTime.fromMillisecondsSinceEpoch(rows.first['saved_at'] as int),
      );
    });
  }

  // ---- E-receipts --------------------------------------------------------------

  static int _createdMs(Map<String, dynamic> row) {
    final raw = row['created_at'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    return (parsed ?? DateTime.now()).millisecondsSinceEpoch;
  }

  /// Saves the full receipt data of orders fetched from the server.
  Future<void> saveServerReceipts(String scope, String branchId, List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return Future.value();
    return _guard((db) async {
      final now = _nowMs;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final row in rows) {
          final id = row['id'] as String?;
          if (id == null) continue;
          batch.insert(
            'staff_order_receipts',
            {
              'scope': scope,
              'order_id': id,
              'branch_id': branchId,
              'json': jsonEncode(row),
              'created_at': _createdMs(row),
              'sync_status': LocalSyncState.synced.name,
              'local_operation_id': null,
              'server_order_id': null,
              'last_error': null,
              'saved_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        // Keep the newest server receipts only (offline sales are never pruned).
        await txn.rawDelete(
          'DELETE FROM staff_order_receipts WHERE scope = ? AND branch_id = ? '
              'AND local_operation_id IS NULL AND order_id NOT IN ('
              'SELECT order_id FROM staff_order_receipts WHERE scope = ? AND branch_id = ? '
              'AND local_operation_id IS NULL ORDER BY created_at DESC LIMIT ?)',
          [scope, branchId, scope, branchId, maxStoredReceipts],
        );
      });
    });
  }

  /// Receipts for a branch, newest first: server orders plus sales rung up
  /// on this device.
  Future<List<StoredReceipt>> receipts(String scope, String branchId, {int limit = 200}) {
    return _read(const <StoredReceipt>[], (db) async {
      final rows = await db.query(
        'staff_order_receipts',
        where: 'scope = ? AND branch_id = ?',
        whereArgs: [scope, branchId],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(StoredReceipt.fromRow).toList();
    });
  }

  /// Only the receipts of sales made on this device (any sync state).
  Future<List<StoredReceipt>> localReceipts(String scope, String branchId) {
    return _read(const <StoredReceipt>[], (db) async {
      final rows = await db.query(
        'staff_order_receipts',
        where: 'scope = ? AND branch_id = ? AND local_operation_id IS NOT NULL',
        whereArgs: [scope, branchId],
        orderBy: 'created_at DESC',
      );
      return rows.map(StoredReceipt.fromRow).toList();
    });
  }

  Future<StoredReceipt?> receipt(String scope, String orderId) {
    return _read(null, (db) async {
      final rows = await db.query(
        'staff_order_receipts',
        where: 'scope = ? AND order_id = ?',
        whereArgs: [scope, orderId],
        limit: 1,
      );
      return rows.isEmpty ? null : StoredReceipt.fromRow(rows.first);
    });
  }

  /// Stores the receipt of a sale rung up offline ("Pending sync").
  Future<void> savePendingReceipt(
      String scope, {
        required String branchId,
        required String orderId,
        required String localOperationId,
        required Map<String, dynamic> json,
      }) async {
    await _guard((db) async {
      await db.insert(
        'staff_order_receipts',
        {
          'scope': scope,
          'order_id': orderId,
          'branch_id': branchId,
          'json': jsonEncode(json),
          'created_at': _createdMs(json),
          'sync_status': LocalSyncState.pending.name,
          'local_operation_id': localOperationId,
          'server_order_id': null,
          'last_error': null,
          'saved_at': _nowMs,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    notifyListeners();
  }

  /// The server accepted an offline sale: the local receipt stays (no longer
  /// "Pending sync") until the server's own copy of [serverOrderId] arrives.
  Future<void> markReceiptSynced(String scope, String localOperationId, String serverOrderId) async {
    await _guard((db) async {
      await db.update(
        'staff_order_receipts',
        {'sync_status': LocalSyncState.synced.name, 'server_order_id': serverOrderId, 'last_error': null},
        where: 'scope = ? AND local_operation_id = ?',
        whereArgs: [scope, localOperationId],
      );
    });
    notifyListeners();
  }

  Future<void> markReceiptState(String scope, String localOperationId, LocalSyncState state, {String? error}) async {
    await _guard((db) async {
      await db.update(
        'staff_order_receipts',
        {'sync_status': state.name, 'last_error': error},
        where: 'scope = ? AND local_operation_id = ?',
        whereArgs: [scope, localOperationId],
      );
    });
    notifyListeners();
  }

  /// Drops local receipts whose server order is now among [serverOrderIds]
  /// (the server copy replaces them — reconciliation).
  Future<void> dropReconciledReceipts(String scope, Set<String> serverOrderIds) {
    if (serverOrderIds.isEmpty) return Future.value();
    return _quiet((db) async {
      final rows = await db.query(
        'staff_order_receipts',
        columns: ['order_id', 'server_order_id'],
        where: 'scope = ? AND local_operation_id IS NOT NULL AND server_order_id IS NOT NULL',
        whereArgs: [scope],
      );
      for (final r in rows) {
        if (serverOrderIds.contains(r['server_order_id'])) {
          await db.delete('staff_order_receipts',
              where: 'scope = ? AND order_id = ?', whereArgs: [scope, r['order_id']]);
        }
      }
    });
  }

  // ---- Inventory movements -------------------------------------------------------

  Future<void> addMovement(String scope, LocalMovement movement) async {
    await _guard((db) async {
      await db.insert('staff_inventory_movements', movement.toRow(scope));
    });
    notifyListeners();
  }

  /// Movements the server copy taken at [snapshotTime] does not include yet:
  /// pending / failed ones, and synced ones accepted after that copy was taken.
  Future<List<LocalMovement>> unreconciledMovements(String scope, String branchId, DateTime snapshotTime) {
    return _read(const <LocalMovement>[], (db) async {
      final rows = await db.query(
        'staff_inventory_movements',
        where: "scope = ? AND branch_id = ? AND (sync_status = 'pending' "
            "OR (sync_status = 'synced' AND synced_at > ?))",
        whereArgs: [scope, branchId, snapshotTime.millisecondsSinceEpoch],
        orderBy: 'created_at ASC',
      );
      return rows.map(LocalMovement.fromRow).toList();
    });
  }

  Future<LocalMovement?> movement(String scope, String id) {
    return _read(null, (db) async {
      final rows = await db.query('staff_inventory_movements',
          where: 'scope = ? AND id = ?', whereArgs: [scope, id], limit: 1);
      return rows.isEmpty ? null : LocalMovement.fromRow(rows.first);
    });
  }

  Future<void> markMovement(String scope, String id, LocalSyncState state, {String? error}) async {
    await _guard((db) async {
      await db.update(
        'staff_inventory_movements',
        {
          'sync_status': state.name,
          'last_error': error,
          if (state == LocalSyncState.synced) 'synced_at': _nowMs,
        },
        where: 'scope = ? AND id = ?',
        whereArgs: [scope, id],
      );
    });
    notifyListeners();
  }

  // ---- Products made offline ---------------------------------------------------------

  Future<void> savePendingProduct(String scope, PendingProduct product) async {
    await _guard((db) async {
      await db.insert(
        'staff_pending_products',
        {
          'scope': scope,
          'id': product.id,
          'operation': product.operation,
          'local_operation_id': product.localOperationId,
          'json': jsonEncode(product.data),
          'created_at': product.createdAt.millisecondsSinceEpoch,
          'sync_status': product.syncState.name,
          'last_error': product.lastError,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    notifyListeners();
  }

  Future<List<PendingProduct>> pendingProducts(String scope) {
    return _read(const <PendingProduct>[], (db) async {
      final rows = await db.query('staff_pending_products',
          where: 'scope = ?', whereArgs: [scope], orderBy: 'created_at ASC');
      return rows.map(PendingProduct.fromRow).toList();
    });
  }

  /// The server has the product now: it shows from the catalog again.
  Future<void> removePendingProduct(String scope, String localOperationId) async {
    await _guard((db) async {
      await db.delete('staff_pending_products',
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
    });
    notifyListeners();
  }

  Future<void> markProductFailed(String scope, String localOperationId, String? error) async {
    await _guard((db) async {
      await db.update('staff_pending_products', {'sync_status': LocalSyncState.failed.name, 'last_error': error},
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
    });
    notifyListeners();
  }

  // ---- Queue housekeeping ------------------------------------------------------------

  /// A failed queued change was retried: its local records are pending again.
  Future<void> markOperationPending(String scope, String localOperationId) async {
    await _guard((db) async {
      await db.update('staff_inventory_movements', {'sync_status': LocalSyncState.pending.name, 'last_error': null},
          where: 'scope = ? AND id = ?', whereArgs: [scope, localOperationId]);
      await db.update('staff_pending_products', {'sync_status': LocalSyncState.pending.name, 'last_error': null},
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
      await db.update('staff_order_receipts', {'sync_status': LocalSyncState.pending.name, 'last_error': null},
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
    });
    notifyListeners();
  }

  /// A person discarded a failed queued change: forget its local records too.
  Future<void> forgetOperation(String scope, String localOperationId) async {
    await _guard((db) async {
      await db.delete('staff_inventory_movements', where: 'scope = ? AND id = ?', whereArgs: [scope, localOperationId]);
      await db.delete('staff_pending_products',
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
      await db.delete('staff_order_receipts',
          where: 'scope = ? AND local_operation_id = ?', whereArgs: [scope, localOperationId]);
    });
    notifyListeners();
  }

  /// Tidies records the server has long had, and removes cached copies that
  /// belong to other accounts (unsent changes of other accounts are kept,
  /// owned by them, exactly like the sync queue).
  Future<void> tidy(String scope) {
    return _quiet((db) async {
      final cutoff = _now().subtract(keepSyncedFor).millisecondsSinceEpoch;
      await db.delete('staff_inventory_movements',
          where: "sync_status = 'synced' AND synced_at < ?", whereArgs: [cutoff]);
      await db.delete('staff_order_receipts',
          where: "local_operation_id IS NOT NULL AND sync_status = 'synced' AND saved_at < ?", whereArgs: [cutoff]);
      await db.delete('staff_snapshots', where: 'scope <> ?', whereArgs: [scope]);
      await db.delete('staff_order_receipts', where: 'scope <> ? AND local_operation_id IS NULL', whereArgs: [scope]);
      await db.delete('staff_local_notifications', where: 'scope <> ?', whereArgs: [scope]);
    });
  }

  /// Sign-out: erases the saved copies of [scope]'s branch data (inventory,
  /// dashboard, server e-receipts, local notifications, records of changes
  /// the server already accepted). Changes not yet sent
  /// (and their receipts) are KEPT, owned by that account only, exactly like
  /// the sync queue; the expired-batch list (batch ids only) is kept so a
  /// batch is never announced twice.
  Future<void> clearCopiesForSignOut(String scope) async {
    await _quiet((db) async {
      await db.delete('staff_snapshots', where: 'scope = ?', whereArgs: [scope]);
      await db.delete('staff_order_receipts',
          where: "scope = ? AND (local_operation_id IS NULL OR sync_status = 'synced')", whereArgs: [scope]);
      await db.delete('staff_local_notifications', where: 'scope = ?', whereArgs: [scope]);
      await db.delete('staff_inventory_movements', where: "scope = ? AND sync_status = 'synced'", whereArgs: [scope]);
    });
  }

  // ---- Expired-stock alerts ------------------------------------------------------------

  /// Records that [batchId]'s expiry was announced. Returns true only the
  /// first time (one notification per batch, never repeated).
  Future<bool> claimExpiryAlert(String scope, String batchId, int expiredQuantity) {
    return _read(false, (db) => db.transaction((txn) async {
      final existing = await txn.query('staff_expiry_alerts',
          where: 'scope = ? AND batch_id = ?', whereArgs: [scope, batchId], limit: 1);
      if (existing.isNotEmpty) return false;
      await txn.insert('staff_expiry_alerts', {
        'scope': scope,
        'batch_id': batchId,
        'expired_quantity': expiredQuantity,
        'notified_at': _nowMs,
      });
      return true;
    }));
  }

  // ---- Local notifications -----------------------------------------------------------------

  /// Adds (or replaces, same id) a notification raised on this device.
  Future<void> putNotification(String scope, StaffNotification n) async {
    await _guard((db) async {
      await db.insert(
        'staff_local_notifications',
        {
          'scope': scope,
          'id': n.id,
          'category': n.category,
          'title': n.title,
          'body': n.body,
          'reference': n.reference,
          'read': n.read ? 1 : 0,
          'created_at': n.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    notifyListeners();
  }

  Future<List<StaffNotification>> notifications(String scope) {
    return _read(const <StaffNotification>[], (db) async {
      final rows = await db.query('staff_local_notifications',
          where: 'scope = ?', whereArgs: [scope], orderBy: 'created_at DESC', limit: 100);
      return [
        for (final r in rows)
          StaffNotification(
            id: r['id'] as String,
            category: r['category'] as String,
            title: r['title'] as String,
            body: r['body'] as String,
            reference: r['reference'] as String?,
            read: (r['read'] as int?) == 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
          ),
      ];
    });
  }

  Future<void> markNotificationsRead(String scope, {String? id}) async {
    await _quiet((db) async {
      await db.update('staff_local_notifications', {'read': 1},
          where: id == null ? 'scope = ?' : 'scope = ? AND id = ?', whereArgs: id == null ? [scope] : [scope, id]);
    });
    notifyListeners();
  }

  Future<void> deleteNotification(String scope, String id) async {
    await _quiet((db) async {
      await db.delete('staff_local_notifications', where: 'scope = ? AND id = ?', whereArgs: [scope, id]);
    });
    notifyListeners();
  }
}
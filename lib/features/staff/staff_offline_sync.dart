import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/connectivity_service.dart';
import '../../core/services/staff_offline_store.dart';
import '../../core/services/staff_session_store.dart';
import '../../core/services/sync_service.dart';
import '../../core/utils/app_error.dart';
import '../../data/models/sync_operation.dart';
import '../../data/repositories/products_repository.dart';
import '../../data/repositories/staff_repository.dart';

/// What happened to a change a staff member saved.
enum SaveOutcome {
  /// The server accepted it right away.
  saved,

  /// No connection: it is saved on this device ("Pending sync") and will be
  /// sent automatically when the connection returns.
  queued,
}

/// A random RFC 4122 version 4 UUID (ids for products created offline).
String newUuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String hex(int from, int to) => b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Staff work that keeps going without a connection: create / edit products,
/// receive stock and adjust stock.
///
/// ONLINE the change goes straight to the database as before. OFFLINE (or when
/// the request cannot reach the server) it is saved on the device twice over:
///   * as a queued operation ([SyncService], SQLite `sync_operations`), and
///   * as the local record the screens show ([StaffOfflineStore]: a stock
///     movement, or a pending product) with a "Pending sync" indicator.
///
/// NO DUPLICATES: the queued operation's id IS the request's idempotency key
/// (and, for a new product, the product id is made on the device), so a send
/// that is retried after an unclear failure is applied by the server once.
/// A change the server refuses becomes "failed" for a person to retry or
/// discard — it is never dropped silently.
class StaffOfflineSync {
  StaffOfflineSync._();
  static final StaffOfflineSync instance = StaffOfflineSync._();

  static const String productCreate = 'product.create';
  static const String productSave = 'product.save';
  static const String inventoryReceive = 'inventory.receive';
  static const String inventoryAdjust = 'inventory.adjust';

  final SyncService _sync = SyncService.instance;
  final StaffOfflineStore _offline = StaffOfflineStore.instance;
  final StaffRepository _repo = StaffRepository.instance;

  /// Call once at start-up (main.dart).
  void register() {
    _sync.registerHandler(productCreate, _deliverProductCreate);
    _sync.registerHandler(productSave, _deliverProductSave);
    _sync.registerHandler(inventoryReceive, _deliverReceive);
    _sync.registerHandler(inventoryAdjust, _deliverAdjust);
  }

  String get _scope {
    final uid = StaffSessionStore.instance.ownerUid;
    if (uid == null) throw AppErrors.accessDenied();
    return uid;
  }

  /// Runs [online] when the device has a connection; returns false when the
  /// request could not reach the server (so it should be queued instead).
  /// While earlier changes are still waiting in the queue, a new one queues
  /// behind them, so the server applies them in the order they were made.
  Future<bool> _tryOnline(Future<void> Function() online, {bool queueOnly = false}) async {
    if (queueOnly || !ConnectivityService.instance.isOnline || _sync.pendingCount > 0) return false;
    try {
      await online();
      return true;
    } catch (e) {
      if (AppErrors.from(e).isConnectivity) return false;
      rethrow;
    }
  }

  // ---- Receive stock ---------------------------------------------------------

  Future<SaveOutcome> receiveBatch({
    required String branchId,
    required String productId,
    required String variantId,
    required String batchCode,
    required int quantity,
    required DateTime expirationDate,
    required DateTime receivedDate,
    int? restockThreshold,
    bool assignExisting = false,
    required String requestKey,

    /// Queue behind earlier changes still waiting to sync (e.g. stock for a
    /// product that was itself created offline).
    bool queueOnly = false,
  }) async {
    final payload = <String, dynamic>{
      'branch_id': branchId,
      'variant_id': variantId,
      'batch_code': batchCode,
      'quantity': quantity,
      'expiration_date': expirationDate.toIso8601String(),
      'received_date': receivedDate.toIso8601String(),
      'restock_threshold': restockThreshold,
      'assign_existing': assignExisting,
    };
    final sent = await _tryOnline(() => _sendReceive(payload, requestKey), queueOnly: queueOnly);
    if (sent) return SaveOutcome.saved;
    final scope = _scope;
    await _queueMovement(
      scope,
      LocalMovement(
        id: requestKey,
        branchId: branchId,
        productId: productId,
        variantId: variantId,
        batchCode: batchCode,
        movementType: 'receive',
        quantityChange: quantity,
        assignExisting: assignExisting,
        reason: assignExisting ? 'Assigned to batch' : 'Received',
        receivedDate: receivedDate,
        expirationDate: expirationDate,
        restockThreshold: restockThreshold,
        staffUid: scope,
        createdAt: DateTime.now(),
      ),
      inventoryReceive,
      'inventory_batch',
      payload,
    );
    return SaveOutcome.queued;
  }

  Future<void> _sendReceive(Map<String, dynamic> p, String key) => _repo.receiveBatch(
        branchId: p['branch_id'] as String,
        variantId: p['variant_id'] as String,
        batchCode: p['batch_code'] as String,
        quantity: (p['quantity'] as num).toInt(),
        expirationDate: DateTime.parse(p['expiration_date'] as String),
        receivedDate: DateTime.parse(p['received_date'] as String),
        restockThreshold: (p['restock_threshold'] as num?)?.toInt(),
        assignExisting: (p['assign_existing'] as bool?) ?? false,
        idempotencyKey: key,
      );

  // ---- Adjust stock ------------------------------------------------------------

  /// Returns the server's `{previous_quantity, new_quantity, adjustment}`, or
  /// null when the adjustment was saved on this device to sync later.
  Future<Map<String, dynamic>?> adjustBatch({
    required String branchId,
    required String productId,
    required String variantId,
    required String batchId,
    required String batchCode,
    required int delta,
    required String reason,
    String? note,
    required String requestKey,
    bool queueOnly = false,
  }) async {
    final payload = <String, dynamic>{'batch_id': batchId, 'delta': delta, 'reason': reason, 'note': note};
    Map<String, dynamic>? result;
    final sent = await _tryOnline(() async {
      result = await _sendAdjust(payload, requestKey);
    }, queueOnly: queueOnly);
    if (sent) return result;
    final scope = _scope;
    await _queueMovement(
      scope,
      LocalMovement(
        id: requestKey,
        branchId: branchId,
        productId: productId,
        variantId: variantId,
        batchId: batchId,
        batchCode: batchCode,
        movementType: 'adjust',
        quantityChange: delta,
        reason: reason,
        note: note,
        staffUid: scope,
        createdAt: DateTime.now(),
      ),
      inventoryAdjust,
      'inventory_batch',
      payload,
    );
    return null;
  }

  Future<Map<String, dynamic>> _sendAdjust(Map<String, dynamic> p, String key) => _repo.adjustBatch(
        batchId: p['batch_id'] as String,
        delta: (p['delta'] as num).toInt(),
        reason: p['reason'] as String,
        note: p['note'] as String?,
        idempotencyKey: key,
      );

  /// The local record first (so the screens can show it), then the queued
  /// operation. If queueing fails the record is removed again: nothing is
  /// ever shown as "Pending sync" that will not actually be sent.
  Future<void> _queueMovement(
    String scope,
    LocalMovement movement,
    String operationType,
    String entityType,
    Map<String, dynamic> payload,
  ) async {
    await _offline.addMovement(scope, movement);
    try {
      await _sync.enqueue(
        operationType: operationType,
        entityType: entityType,
        entityId: movement.batchId ?? movement.variantId,
        localOperationId: movement.id,
        payload: payload,
      );
    } catch (_) {
      await _offline.forgetOperation(scope, movement.id);
      rethrow;
    }
  }

  // ---- Products -------------------------------------------------------------------

  /// New product. Offline it gets its ids on this device and shows in the
  /// product and inventory lists right away, marked "Pending sync".
  Future<SaveOutcome> createProduct({
    required String name,
    required String description,
    String? categoryId,
    required double price,
    double? costPrice,
    required bool isActive,
    required List<String> branchIds,
  }) async {
    final productId = newUuidV4();
    final variantId = newUuidV4();
    final payload = <String, dynamic>{
      'product_id': productId,
      'variant_id': variantId,
      'name': name,
      'description': description,
      'category_id': categoryId,
      'price': price,
      'cost_price': costPrice,
      'is_active': isActive,
      'branch_ids': branchIds,
    };
    final sent = await _tryOnline(() => _sendProductCreate(payload));
    if (sent) return SaveOutcome.saved;
    final scope = _scope;
    final opId = 'product-$productId';
    await _offline.savePendingProduct(
      scope,
      PendingProduct(
        id: productId,
        operation: 'create',
        localOperationId: opId,
        data: payload,
        createdAt: DateTime.now(),
      ),
    );
    try {
      await _sync.enqueue(
        operationType: productCreate,
        entityType: 'product',
        entityId: productId,
        localOperationId: opId,
        payload: payload,
      );
    } catch (_) {
      await _offline.forgetOperation(scope, opId);
      rethrow;
    }
    return SaveOutcome.queued;
  }

  Future<void> _sendProductCreate(Map<String, dynamic> p) => _repo.createProductWithIds(
        productId: p['product_id'] as String,
        variantId: p['variant_id'] as String,
        name: p['name'] as String,
        description: (p['description'] as String?) ?? '',
        categoryId: p['category_id'] as String?,
        price: (p['price'] as num).toDouble(),
        costPrice: (p['cost_price'] as num?)?.toDouble(),
        isActive: (p['is_active'] as bool?) ?? true,
        branchIds: ((p['branch_ids'] as List?) ?? const []).map((e) => '$e').toList(),
      );

  /// Edit of an existing product (same values as `staff_save_product`).
  /// Sending the same edit twice leaves the same result, so a retry is safe.
  Future<SaveOutcome> saveProduct({
    required String productId,
    required String name,
    required String description,
    String? categoryId,
    required double price,
    String? sku,
    List<String> images = const [],
    bool isActive = true,
    bool isFeatured = false,
    List<Map<String, dynamic>> variants = const [],
    List<String> branchIds = const [],
  }) async {
    final payload = <String, dynamic>{
      'product_id': productId,
      'name': name,
      'description': description,
      'category_id': categoryId,
      'price': price,
      'sku': sku,
      'images': images,
      'is_active': isActive,
      'is_featured': isFeatured,
      'variants': variants,
      'branch_ids': branchIds,
    };
    final sent = await _tryOnline(() => _sendProductSave(payload));
    if (sent) return SaveOutcome.saved;
    final scope = _scope;
    final opId = 'product-edit-$productId-${DateTime.now().microsecondsSinceEpoch}';
    await _offline.savePendingProduct(
      scope,
      PendingProduct(
        id: productId,
        operation: 'update',
        localOperationId: opId,
        data: payload,
        createdAt: DateTime.now(),
      ),
    );
    try {
      await _sync.enqueue(
        operationType: productSave,
        entityType: 'product',
        entityId: productId,
        localOperationId: opId,
        payload: payload,
      );
    } catch (_) {
      await _offline.forgetOperation(scope, opId);
      rethrow;
    }
    return SaveOutcome.queued;
  }

  Future<void> _sendProductSave(Map<String, dynamic> p) => _repo.saveProduct(
        productId: p['product_id'] as String,
        name: p['name'] as String,
        description: (p['description'] as String?) ?? '',
        categoryId: p['category_id'] as String?,
        price: (p['price'] as num).toDouble(),
        sku: p['sku'] as String?,
        images: ((p['images'] as List?) ?? const []).map((e) => '$e').toList(),
        isActive: (p['is_active'] as bool?) ?? true,
        isFeatured: (p['is_featured'] as bool?) ?? false,
        variants: ((p['variants'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList(),
        branchIds: ((p['branch_ids'] as List?) ?? const []).map((e) => '$e').toList(),
      );

  // ---- Sync handlers (SyncService) ------------------------------------------------

  /// Sends one queued change; maps the outcome like the POS sale queue does:
  /// no connection -> stays pending; the database refused -> failed.
  Future<void> _deliver(SyncOperation op, Future<void> Function() send, Future<void> Function(String message) onRefused) async {
    try {
      await send();
    } catch (e) {
      final mapped = AppErrors.from(e);
      if (mapped.isConnectivity || mapped.kind == AppErrorKind.authExpired) rethrow;
      if (e is PostgrestException || e is AppError) {
        await onRefused(mapped.message);
        throw SyncRejectedException(mapped.message);
      }
      rethrow;
    }
  }

  Future<void> _deliverReceive(SyncOperation op) async {
    final scope = op.staffFirebaseUid;
    await _deliver(
      op,
      () => _sendReceive(op.payload, op.localOperationId),
      (m) => _offline.markMovement(scope, op.localOperationId, LocalSyncState.failed, error: m),
    );
    await _offline.markMovement(scope, op.localOperationId, LocalSyncState.synced);
  }

  Future<void> _deliverAdjust(SyncOperation op) async {
    final scope = op.staffFirebaseUid;
    await _deliver(
      op,
      () => _sendAdjust(op.payload, op.localOperationId),
      (m) => _offline.markMovement(scope, op.localOperationId, LocalSyncState.failed, error: m),
    );
    await _offline.markMovement(scope, op.localOperationId, LocalSyncState.synced);
  }

  Future<void> _deliverProductCreate(SyncOperation op) async {
    final scope = op.staffFirebaseUid;
    await _deliver(
      op,
      () => _sendProductCreate(op.payload),
      (m) => _offline.markProductFailed(scope, op.localOperationId, m),
    );
    // The catalog first, so the product never disappears in between.
    await _reloadCatalog();
    await _offline.removePendingProduct(scope, op.localOperationId);
  }

  Future<void> _deliverProductSave(SyncOperation op) async {
    final scope = op.staffFirebaseUid;
    await _deliver(
      op,
      () => _sendProductSave(op.payload),
      (m) => _offline.markProductFailed(scope, op.localOperationId, m),
    );
    await _reloadCatalog();
    await _offline.removePendingProduct(scope, op.localOperationId);
  }

  Future<void> _reloadCatalog() async {
    try {
      await ProductsRepository.instance.loadCatalog();
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'staff_offline_sync:catalog');
    }
  }

  // ---- Queue sheet helpers --------------------------------------------------------

  /// A person retried a failed change: pending again, same key, sent if possible.
  Future<void> retry(SyncOperation op) async {
    await _offline.markOperationPending(op.staffFirebaseUid, op.localOperationId);
    await _sync.retryFailed(op.localOperationId);
  }

  /// A person discarded a failed change: it and its local record are gone.
  Future<void> discard(SyncOperation op) async {
    await _sync.discardFailed(op.localOperationId);
    await _offline.forgetOperation(op.staffFirebaseUid, op.localOperationId);
  }
}

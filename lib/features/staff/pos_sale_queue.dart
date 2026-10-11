import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/sync_service.dart';
import '../../core/utils/app_error.dart';
import '../../data/models/sync_operation.dart';
import '../../data/repositories/staff_repository.dart';

/// Sends one POS sale to the database; the same signature as
/// [StaffRepository.createPosSale] reduced to what the queue stores.
typedef PosSaleSubmit = Future<void> Function({
  required String branchId,
  required Map<String, int> quantitiesByVariant,
  required String paymentMethod,
  required String idempotencyKey,
  String? paymentReference,
  double? cashReceived,
  String? customerUid,
});

/// OFFLINE POS QUEUE (roadmap item): a sale rung up while the register has no
/// connection is saved on the device (SQLite, [SyncService]) and replayed when
/// the connection returns.
///
/// NEVER DOUBLE-CHARGED: the queue's operation id IS the sale's idempotency
/// key, so a replay after an unclear failure returns the sale the database
/// already stored instead of creating a second one. Stock, totals and payment
/// are still computed by the database when the sale arrives; a sale the
/// database refuses (e.g. not enough stock any more, no open shift) becomes
/// "failed" for a person to retry or discard — it is never dropped silently.
class PosSaleQueue {
  PosSaleQueue({SyncService? sync, PosSaleSubmit? submit})
      : _sync = sync ?? SyncService.instance,
        _submit = submit ?? _submitWithRepository;

  static final PosSaleQueue instance = PosSaleQueue();

  static const String operationType = 'pos.sale';

  final SyncService _sync;
  final PosSaleSubmit _submit;

  static Future<void> _submitWithRepository({
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    required String idempotencyKey,
    String? paymentReference,
    double? cashReceived,
    String? customerUid,
  }) async {
    await StaffRepository.instance.createPosSale(
      branchId: branchId,
      quantitiesByVariant: quantitiesByVariant,
      paymentMethod: paymentMethod,
      idempotencyKey: idempotencyKey,
      paymentReference: paymentReference,
      cashReceived: cashReceived,
      customerUid: customerUid,
    );
  }

  /// Call once at start-up (main.dart).
  void register() => _sync.registerHandler(operationType, deliver);

  /// Saves the sale on the device. [idempotencyKey] is the checkout's key.
  Future<SyncOperation> enqueue({
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    required String idempotencyKey,
    String? paymentReference,
    double? cashReceived,
    String? customerUid,
    double? displayedTotal,
  }) {
    return _sync.enqueue(
      operationType: operationType,
      entityType: 'pos_sale',
      entityId: idempotencyKey,
      localOperationId: idempotencyKey,
      payload: {
        'branch_id': branchId,
        'items': {for (final e in quantitiesByVariant.entries) e.key: e.value},
        'payment_method': paymentMethod,
        'payment_reference': paymentReference,
        'cash_received': cashReceived,
        'customer_uid': customerUid,
        // Shown in the pending list only; the database computes the real total.
        'displayed_total': displayedTotal,
      },
    );
  }

  /// The [SyncHandler]: sends a queued sale.
  Future<void> deliver(SyncOperation op) async {
    final p = op.payload;
    final items = <String, int>{
      for (final e in Map<String, dynamic>.from(p['items'] as Map).entries) e.key: (e.value as num).toInt(),
    };
    try {
      await _submit(
        branchId: p['branch_id'] as String,
        quantitiesByVariant: items,
        paymentMethod: p['payment_method'] as String,
        idempotencyKey: op.localOperationId,
        paymentReference: p['payment_reference'] as String?,
        cashReceived: (p['cash_received'] as num?)?.toDouble(),
        customerUid: p['customer_uid'] as String?,
      );
    } catch (e) {
      final mapped = AppErrors.from(e);
      // No connection / signed out: SyncService keeps it pending and retries.
      if (mapped.isConnectivity || mapped.kind == AppErrorKind.authExpired) rethrow;
      // The database answered and refused the sale: a person must decide.
      if (e is PostgrestException || e is AppError) throw SyncRejectedException(mapped.message);
      rethrow;
    }
  }

  Future<List<SyncOperation>> pending() => _sync.operations(SyncStatus.pending, operationType: operationType);
  Future<List<SyncOperation>> failed() => _sync.operations(SyncStatus.failed, operationType: operationType);
  Future<void> retry(String id) => _sync.retryFailed(id);
  Future<void> discard(String id) => _sync.discardFailed(id);
}

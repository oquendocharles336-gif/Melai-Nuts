import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/staff_offline_store.dart';
import '../../core/services/staff_store.dart';
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

/// Keeps the e-receipt of a sale rung up offline on the device, so it shows
/// in Recent Orders (marked "Pending sync") before the device reconnects.
abstract class PosReceiptBook {
  Future<void> saveOfflineReceipt({
    required String localOperationId,
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    String? paymentReference,
    double? cashReceived,
    double? displayedTotal,
  });

  Future<void> markSent(String staffUid, String localOperationId, String? serverOrderId);
  Future<void> markRefused(String staffUid, String localOperationId, String message);
}

/// The app's receipt book: SQLite via [StaffOfflineStore], item names and
/// prices from what the register showed when the sale was rung up.
class _DeviceReceiptBook implements PosReceiptBook {
  const _DeviceReceiptBook();

  @override
  Future<void> saveOfflineReceipt({
    required String localOperationId,
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    String? paymentReference,
    double? cashReceived,
    double? displayedTotal,
  }) async {
    final store = StaffStore.instance;
    final scope = store.profile?.uid;
    if (scope == null) return;
    var cents = 0;
    final items = <Map<String, dynamic>>[];
    quantitiesByVariant.forEach((variantId, qty) {
      final item = store.itemByVariant(variantId);
      final price = item?.price ?? 0;
      cents += (price * 100).round() * qty;
      items.add({
        'variant_id': variantId,
        'product_name': item?.productName ?? 'Item',
        'variant_label': item?.variantLabel ?? '',
        'quantity': qty,
        'unit_price': price,
      });
    });
    final total = displayedTotal ?? cents / 100;
    // A readable local order number until the server assigns the real one.
    final tail = localOperationId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final number = 'OFFLINE-${(tail.length > 6 ? tail.substring(tail.length - 6) : tail).toUpperCase()}';
    final change = cashReceived == null ? null : (cashReceived - total).clamp(0, double.infinity).toDouble();
    await StaffOfflineStore.instance.savePendingReceipt(
      scope,
      branchId: branchId,
      orderId: number,
      localOperationId: localOperationId,
      json: {
        'id': number,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'status': 'completed',
        'branch_name': store.activeBranchName,
        'is_delivery': false,
        'subtotal': total,
        'discount': 0,
        'delivery_fee': 0,
        'total': total,
        'payment_method': paymentMethod,
        'points_earned': 0,
        'customer_notes': '',
        'contact_phone': '',
        'is_pos': true,
        'cashier_name': store.profile?.fullName,
        'cash_received': cashReceived,
        'change_given': change,
        'items': items,
        'payment': {
          'id': '',
          'method': paymentMethod,
          'status': 'pending',
          'reference_number': paymentReference ?? '',
          'amount': total,
        },
      },
    );
  }

  @override
  Future<void> markSent(String staffUid, String localOperationId, String? serverOrderId) =>
      StaffOfflineStore.instance.markReceiptSynced(staffUid, localOperationId, serverOrderId ?? '');

  @override
  Future<void> markRefused(String staffUid, String localOperationId, String message) =>
      StaffOfflineStore.instance.markReceiptState(staffUid, localOperationId, LocalSyncState.failed, error: message);
}

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
  PosSaleQueue({SyncService? sync, PosSaleSubmit? submit, PosReceiptBook? receipts})
      : _sync = sync ?? SyncService.instance,
        _submit = submit ?? _submitWithRepository,
        // The app (no custom submit) keeps offline e-receipts on the device.
        _receipts = receipts ?? (submit == null ? const _DeviceReceiptBook() : null);

  static final PosSaleQueue instance = PosSaleQueue();

  static const String operationType = 'pos.sale';

  final SyncService _sync;
  final PosSaleSubmit _submit;
  final PosReceiptBook? _receipts;

  /// Server order ids of sales just sent by [_submitWithRepository], by key.
  static final Map<String, String> _sentOrderIds = {};

  static Future<void> _submitWithRepository({
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    required String idempotencyKey,
    String? paymentReference,
    double? cashReceived,
    String? customerUid,
  }) async {
    final result = await StaffRepository.instance.createPosSale(
      branchId: branchId,
      quantitiesByVariant: quantitiesByVariant,
      paymentMethod: paymentMethod,
      idempotencyKey: idempotencyKey,
      paymentReference: paymentReference,
      cashReceived: cashReceived,
      customerUid: customerUid,
    );
    _sentOrderIds[idempotencyKey] = result.orderId;
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
  }) async {
    final op = await _sync.enqueue(
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
    // The e-receipt, generated on the device and marked "Pending sync". Best
    // effort: the sale itself is already safely queued.
    try {
      await _receipts?.saveOfflineReceipt(
        localOperationId: op.localOperationId,
        branchId: branchId,
        quantitiesByVariant: quantitiesByVariant,
        paymentMethod: paymentMethod,
        paymentReference: paymentReference,
        cashReceived: cashReceived,
        displayedTotal: displayedTotal,
      );
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'pos_sale_queue:receipt');
    }
    return op;
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
      if (e is PostgrestException || e is AppError) {
        await _receiptQuietly(() => _receipts?.markRefused(op.staffFirebaseUid, op.localOperationId, mapped.message));
        throw SyncRejectedException(mapped.message);
      }
      rethrow;
    }
    final orderId = _sentOrderIds.remove(op.localOperationId);
    await _receiptQuietly(() => _receipts?.markSent(op.staffFirebaseUid, op.localOperationId, orderId));
  }

  static Future<void> _receiptQuietly(Future<void>? Function() action) async {
    try {
      final pending = action();
      if (pending != null) await pending;
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'pos_sale_queue:receipt_state');
    }
  }

  Future<List<SyncOperation>> pending() => _sync.operations(SyncStatus.pending, operationType: operationType);
  Future<List<SyncOperation>> failed() => _sync.operations(SyncStatus.failed, operationType: operationType);
  Future<void> retry(String id) => _sync.retryFailed(id);
  Future<void> discard(String id) => _sync.discardFailed(id);
}

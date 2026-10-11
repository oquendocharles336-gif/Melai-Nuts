import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/supabase_service.dart';
import '../../core/utils/app_error.dart';
import '../models/order.dart';
import '../models/refund.dart';
import '../models/refund_summary.dart';

/// Creates and reads real refund requests in Supabase (`refund_requests` /
/// `refund_items` / `refund_status_events`). Customers can submit a request
/// (via the server-side `request_refund` function) and watch its status; only
/// staff/owner tooling can move it forward — customers have read-only access
/// to these tables.
class RefundsRepository {
  RefundsRepository._();
  static final RefundsRepository instance = RefundsRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Submits a refund through the `request_refund` database function.
  ///
  /// The client only says WHICH order, WHICH lines/quantities and WHY. The
  /// server verifies the order belongs to the signed-in customer and is
  /// completed, prices every line from the order itself, computes the refund
  /// amount and payment method, and always starts the request as `pending`.
  /// Nothing the app sends can influence the amount or the status, so a
  /// modified client cannot ask for more than was paid or approve its own
  /// request. The returned [RefundRequest] carries the server's real values.
  Future<RefundRequest> submitRequest({
    required String orderId,
    required String reason,
    required String notes,
    required List<OrderItem> items,
  }) async {
    final String refundId;
    try {
      final result = await _client.rpc('request_refund', params: {
        'p_order_id': orderId,
        'p_reason': reason,
        'p_notes': notes,
        'p_items': [
          for (final item in items)
            {
              'product_name': item.productName,
              'variant_label': item.variantLabel,
              'quantity': item.quantity,
            },
        ],
      }).timeout(AppErrors.rpcTimeout);
      refundId = result as String;
    } catch (e, st) {
      // Not completed, already refunded, invalid quantities, offline,
      // expired session, database error... all become customer-safe messages.
      Error.throwWithStackTrace(AppErrors.from(e, scope: ErrorScope.refund), st);
    }
    try {
      return await refetch(refundId);
    } catch (_) {
      // The request was recorded; only reloading it failed.
      throw const AppError(
        AppErrorKind.refundFailed,
        'Your refund request was submitted, but we couldn\'t load its status. Please check your orders in a moment.',
      );
    }
  }

  /// The refund state of the signed-in customer's orders, computed by the
  /// database (`get_my_order_refunds`): order id -> refunded / pending amount
  /// and the loyalty points reversed. Only orders with a refund request are
  /// returned; [orderIds] narrows it down.
  Future<Map<String, OrderRefundSummary>> fetchOrderRefunds({List<String>? orderIds}) {
    return AppErrors.guard(() async {
      final raw = await _client
          .rpc('get_my_order_refunds', params: {'p_order_ids': orderIds})
          .timeout(AppErrors.rpcTimeout);
      final out = <String, OrderRefundSummary>{};
      for (final e in (raw as List? ?? const [])) {
        final row = Map<String, dynamic>.from(e as Map);
        final summary = OrderRefundSummary.fromJson(row);
        final id = row['order_id'];
        if (summary != null && id is String) out[id] = summary;
      }
      return out;
    }, scope: ErrorScope.refund);
  }

  Future<Map<String, OrderRefundSummary>>? _myRefunds;
  DateTime? _myRefundsAt;

  /// One order's refund summary, from one shared call for all of the
  /// customer's orders (kept 30 s, so a list of orders makes a single
  /// request). null = the order has no refund request.
  Future<OrderRefundSummary?> orderRefund(String orderId, {bool fresh = false}) async {
    final now = DateTime.now();
    final at = _myRefundsAt;
    if (fresh || _myRefunds == null || at == null || now.difference(at) > const Duration(seconds: 30)) {
      _myRefundsAt = now;
      _myRefunds = fetchOrderRefunds();
    }
    try {
      return (await _myRefunds!)[orderId];
    } catch (_) {
      _myRefunds = null; // try again next time
      rethrow;
    }
  }

  static const String _refundSelect = '*, refund_items(*), refund_status_events(*)';

  Future<List<RefundRequest>> fetchAll(String firebaseUid) {
    return AppErrors.guard(() async {
      final raw = await _client
          .from('refund_requests')
          .select(_refundSelect)
          .eq('firebase_uid', firebaseUid)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(raw).map(_fromEmbeddedRow).toList();
    }, scope: ErrorScope.refund);
  }

  Stream<List<Map<String, dynamic>>> watchRequest(String refundId) {
    return _client
        .from('refund_requests')
        .stream(primaryKey: ['id'])
        .eq('id', refundId)
        .transform(StreamTransformer<List<Map<String, dynamic>>, List<Map<String, dynamic>>>.fromHandlers(
          handleError: (error, stackTrace, sink) =>
              sink.addError(AppErrors.from(error, scope: ErrorScope.refund), stackTrace),
        ));
  }

  Future<RefundRequest> refetch(String refundId) {
    return AppErrors.guard(() async {
      final row =
          await _client.from('refund_requests').select(_refundSelect).eq('id', refundId).single();
      return _fromEmbeddedRow(row);
    }, scope: ErrorScope.refund);
  }

  RefundRequest _fromEmbeddedRow(Map<String, dynamic> row) {
    final events = List<Map<String, dynamic>>.from(row['refund_status_events'] as List? ?? const [])
      ..sort((a, b) => (a['created_at'] as String).compareTo(b['created_at'] as String));
    return RefundRequest.fromRow(
      row,
      itemRows: List<Map<String, dynamic>>.from(row['refund_items'] as List? ?? const []),
      eventRows: events,
    );
  }
}

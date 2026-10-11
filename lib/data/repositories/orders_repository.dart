import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/customer_local_db.dart';
import '../../core/services/supabase_service.dart';
import '../../core/widgets/list_tools.dart';
import '../../core/utils/app_error.dart';
import '../models/order.dart';

class OrdersRepository {
  OrdersRepository._();
  static final OrdersRepository instance = OrdersRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  /// Places the order via the `place_order` RPC. Stock validation, pricing,
  /// the order/order_items rows, the loyalty redemption, and now the
  /// payment record too are all created atomically inside that single
  /// database transaction — this method never writes to
  /// `orders`/`order_items`/`payments`/`branch_inventory` directly, so a
  /// dropped connection partway through can never leave a half-created
  /// order behind.
  ///
  /// [idempotencyKey], when given, must stay the same across every retry of
  /// one checkout attempt (the caller generates it once per attempt — see
  /// `CheckoutScreen`). If a previous call with the same key already
  /// committed an order (the request succeeded but the response never made
  /// it back — a dropped connection, a killed app, a flaky network — this
  /// is genuinely indistinguishable from "it failed" without one), this
  /// returns that same order instead of creating a second one. Safe to omit
  /// for calls that are known not to be a retry.
  Future<Order> createOrderFromCart({
    required String cartId,
    required bool isDelivery,
    String? deliveryAddressId,
    required String paymentMethod,
    String customerNotes = '',
    String? idempotencyKey,
  }) async {
    final String orderId;
    try {
      final result = await _client.rpc('place_order', params: {
        'p_cart_id': cartId,
        'p_is_delivery': isDelivery,
        'p_delivery_address_id': deliveryAddressId,
        'p_payment_method': paymentMethod,
        'p_customer_notes': customerNotes,
        'p_idempotency_key': idempotencyKey,
      }).timeout(AppErrors.rpcTimeout);
      orderId = result as String;
    } catch (e, st) {
      // Every failure — offline, timeout, expired session, out of stock,
      // invalid voucher, not enough points, unavailable branch/product,
      // payment failure, database error — becomes a customer-safe AppError.
      //
      // A gateway/server 5xx says nothing about whether the order was
      // committed, so it is reported exactly like a dropped connection
      // ("couldn't confirm your order") — never as a definitive failure.
      final code = e is PostgrestException ? (e.code ?? '') : '';
      final gatewayFailure = code.length == 3 && code.startsWith('5');
      Error.throwWithStackTrace(
        AppErrors.from(gatewayFailure ? TimeoutException('gateway') : e, scope: ErrorScope.order),
        st,
      );
    }

    // The order is now committed. If loading it back fails (flaky network),
    // do NOT report "order failed" — it wasn't. Retry once, then explain.
    try {
      return await refetch(orderId);
    } catch (caughtError, caughtStack) {
      AppErrors.report(caughtError, caughtStack, 'orders_repository:69');
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        return await refetch(orderId);
      } catch (caughtError, caughtStack) {
        AppErrors.report(caughtError, caughtStack, 'orders_repository:73');
        throw AppError(
          AppErrorKind.orderFailed,
          idempotencyKey != null
              ? 'Your order was placed, but we couldn\'t load its details. '
                  'Tap Place Order again to view it — you won\'t be charged twice.'
              : 'Your order was placed, but we couldn\'t load its details. Please check My Orders.',
        );
      }
    }
  }

  /// Columns fetched with every order: the order row plus its line items,
  /// status history and payment, in ONE round trip (PostgREST embedded
  /// resources) instead of three extra queries per order.
  /// Explicit columns (never `*`): only what the app shows.
  static const String _orderColumns =
      'id,firebase_uid,branch_id,branch_name,is_delivery,delivery_address_id,status,subtotal,discount,'
      'delivery_fee,total,payment_method,points_earned,rider_name,rider_phone,eta_label,created_at,'
      'updated_at,customer_notes,contact_phone,delivery_address_text,delivery_latitude,delivery_longitude';
  static const String _orderSelect = '$_orderColumns,'
      ' order_items(id,order_id,product_name,variant_label,quantity,unit_price,product_id,variant_id),'
      ' order_status_events(id,order_id,status,note,created_at),'
      ' payments(id,order_id,firebase_uid,method,status,amount,reference_number,created_at,updated_at,'
      'gateway,gateway_payment_id,gateway_checkout_url)';

  /// The customer's most recent orders kept in memory (dashboard, active
  /// order, loyalty). Older ones are read page by page ([fetchOrdersPage]).
  static const int recentLimit = 50;

  /// Order statuses grouped as the history screen's filter shows them.
  static const Map<String, List<String>> statusGroups = {
    'active': ['pending', 'confirmed', 'preparing', 'readyForPickup', 'outForDelivery', 'refundRequested'],
    'completed': ['completed'],
    'cancelled': ['cancelled'],
    'refunded': ['refunded'],
  };

  /// Looks up the customer's own order that was created with
  /// [idempotencyKey], or null if the server never accepted one. Used to
  /// settle an unconfirmed checkout (the request went out but the response
  /// never came back) without ever guessing.
  Future<Order?> findByIdempotencyKey(String firebaseUid, String idempotencyKey) {
    return AppErrors.guard(() async {
      final row = await _client
          .from('orders')
          .select(_orderSelect)
          .eq('firebase_uid', firebaseUid)
          .eq('idempotency_key', idempotencyKey)
          .maybeSingle();
      return row == null ? null : _orderFromEmbeddedRow(row);
    }, scope: ErrorScope.order);
  }

  /// The [recentLimit] newest orders. The rows are also saved in the local
  /// database (local-first: shown at once on the next start, and offline).
  Future<List<Order>> fetchOrders(String firebaseUid) {
    return AppErrors.guard(() async {
      final raw = await _client
          .from('orders')
          .select(_orderSelect)
          .eq('firebase_uid', firebaseUid)
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(recentLimit);
      final rows = List<Map<String, dynamic>>.from(raw);
      unawaited(CustomerLocalDb.instance.replaceAll(firebaseUid, LocalKind.orders, rows));
      return rows.map(_orderFromEmbeddedRow).toList();
    }, scope: ErrorScope.order);
  }

  /// The orders saved on this device (last server copy), newest first.
  Future<List<Order>> localOrders(String firebaseUid) async {
    final page = await CustomerLocalDb.instance.query(firebaseUid, LocalKind.orders, sort: LocalSort.newest);
    return page.rows.map(_orderFromEmbeddedRow).toList();
  }

  /// The same page read from the copy saved on this device (offline). The
  /// saved copy holds the orders this device has seen, so `total` counts
  /// those only; the screen labels it as saved data.
  Future<(PageResult<Order>, DateTime?)> localOrdersPage(
      String firebaseUid, ListQuery query, int offset, int limit) async {
    final page = await CustomerLocalDb.instance.query(
      firebaseUid,
      LocalKind.orders,
      search: query.search,
      sort: query.sortId == 'oldest' ? LocalSort.oldest : LocalSort.newest,
    );
    final group = statusGroups[query.filters['status']];
    final days = int.tryParse(query.filters['date'] ?? '');
    final since = days == null ? null : DateTime.now().subtract(Duration(days: days));
    var orders = page.rows.map(_orderFromEmbeddedRow).where((o) {
      if (group != null && !group.contains(o.status.name)) return false;
      if (since != null && o.date.isBefore(since)) return false;
      return true;
    }).toList();
    if (query.sortId == 'totalHigh') orders.sort((a, b) => b.total.compareTo(a.total));
    if (query.sortId == 'totalLow') orders.sort((a, b) => a.total.compareTo(b.total));
    final total = orders.length;
    orders = orders.skip(offset).take(limit).toList();
    return (PageResult(orders, total), page.savedAt);
  }

  /// One page of the customer's orders with search (order ID or branch),
  /// status filter and sort applied BY THE SERVER, plus the total count.
  Future<PageResult<Order>> fetchOrdersPage(String firebaseUid, ListQuery query, int offset, int limit) {
    return AppErrors.guard(() async {
      var q = _client.from('orders').select(_orderSelect).eq('firebase_uid', firebaseUid);
      final term = query.search.replaceAll(RegExp(r'[^A-Za-z0-9 \-]'), '').trim();
      if (term.isNotEmpty) q = q.or('id.ilike.%$term%,branch_name.ilike.%$term%');
      final group = statusGroups[query.filters['status']];
      if (group != null) q = q.inFilter('status', group);
      final days = int.tryParse(query.filters['date'] ?? '');
      if (days != null) {
        q = q.gte('created_at', DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String());
      }
      final ascending = query.sortId == 'oldest' || query.sortId == 'totalLow';
      final column = query.sortId.startsWith('total') ? 'total' : 'created_at';
      final res = await q
          .order(column, ascending: ascending)
          .order('id', ascending: ascending)
          .range(offset, offset + limit - 1)
          .count(CountOption.exact);
      final rows = List<Map<String, dynamic>>.from(res.data);
      unawaited(CustomerLocalDb.instance.upsert(firebaseUid, LocalKind.orders, rows));
      return PageResult(rows.map(_orderFromEmbeddedRow).toList(), res.count);
    }, scope: ErrorScope.order);
  }

  Future<Order> refetch(String orderId) {
    return AppErrors.guard(() async {
      final row = await _client.from('orders').select(_orderSelect).eq('id', orderId).single();
      return _orderFromEmbeddedRow(row);
    }, scope: ErrorScope.order);
  }

  /// Live updates for one order. Stream errors are converted to [AppError]s so
  /// listeners can show a friendly "live updates paused" message.
  Stream<List<Map<String, dynamic>>> watchOrder(String orderId) {
    return _client
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('id', orderId)
        .transform(StreamTransformer<List<Map<String, dynamic>>, List<Map<String, dynamic>>>.fromHandlers(
          handleError: (error, stackTrace, sink) =>
              sink.addError(AppErrors.from(error, scope: ErrorScope.order), stackTrace),
        ));
  }

  /// Live change feed for ALL of this customer's orders (status, rider, ETA).
  /// Events carry the plain `orders` rows only (no items / timeline), so the
  /// listener uses them to detect a change and then re-reads the full orders
  /// with [fetchOrders].
  Stream<List<Map<String, dynamic>>> watchCustomerOrders(String firebaseUid) {
    return _client
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('firebase_uid', firebaseUid)
        .transform(StreamTransformer<List<Map<String, dynamic>>, List<Map<String, dynamic>>>.fromHandlers(
          handleError: (error, stackTrace, sink) =>
              sink.addError(AppErrors.from(error, scope: ErrorScope.order), stackTrace),
        ));
  }

  Order _orderFromEmbeddedRow(Map<String, dynamic> row) {
    final events = _rows(row['order_status_events'])
      ..sort((a, b) => (a['created_at'] as String).compareTo(b['created_at'] as String));
    final payments = _rows(row['payments']);
    return Order.fromRow(
      row,
      itemRows: _rows(row['order_items']),
      eventRows: events,
      paymentRow: payments.isEmpty ? null : payments.first,
    );
  }

  /// An embedded resource comes back as a list for one-to-many and as a
  /// single object (or null) for one-to-one — normalise both to a list.
  List<Map<String, dynamic>> _rows(dynamic value) {
    if (value == null) return <Map<String, dynamic>>[];
    if (value is Map) return [Map<String, dynamic>.from(value)];
    return List<Map<String, dynamic>>.from(value as List);
  }
}

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';
import '../../core/services/supabase_token.dart';
import '../../core/utils/app_error.dart';
import '../models/inventory_batch.dart';
import '../models/inventory_item.dart';
import '../models/owner_sales.dart';
import '../models/staff_models.dart';

/// A product that is switched off in the catalog (`is_active = false`).
/// The shared storefront catalog never loads these, so management screens
/// read them separately in order to offer reactivation.
class InactiveProduct {
  final String id;
  final String name;
  final double price;
  final String? sku;

  const InactiveProduct({
    required this.id,
    required this.name,
    required this.price,
    this.sku,
  });

  factory InactiveProduct.fromJson(Map<String, dynamic> j) => InactiveProduct(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    price: (j['price'] as num?)?.toDouble() ?? 0,
    sku: j['sku'] as String?,
  );
}

/// The inventory read model for one branch.
class StaffInventorySnapshot {
  final String branchId;
  final List<InventoryItem> items;
  final List<InventoryBatch> batches;

  const StaffInventorySnapshot({
    required this.branchId,
    required this.items,
    required this.batches,
  });
}

/// Every staff-side call to the backend.
///
/// All reads/writes go through `staff_*` database functions (or RLS-protected
/// tables). The database — not this class — decides whether the caller is an
/// active staff member, which branch they may touch and which permissions they
/// hold, so a modified app gains nothing by calling these differently.
class StaffRepository {
  StaffRepository._();
  static final StaffRepository instance = StaffRepository._();

  SupabaseClient get _client => SupabaseService.instance.client;

  static const Duration _timeout = Duration(seconds: 30);

  /// Runs an RPC. Messages raised by our own database functions (SQLSTATE
  /// P0001) are written for staff and are shown as-is; anything else is mapped
  /// to a safe, generic message.
  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) async {
    try {
      return await _client.rpc(fn, params: params).timeout(_timeout);
    } on PostgrestException catch (e) {
      if (e.code == 'P0001' && e.message.trim().isNotEmpty) {
        throw AppError(AppErrorKind.unknown, e.message.trim());
      }
      throw AppErrors.from(e);
    } catch (e) {
      throw AppErrors.from(e);
    }
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_timeout);
    } on PostgrestException catch (e) {
      throw AppErrors.from(e);
    } catch (e) {
      throw AppErrors.from(e);
    }
  }

  Map<String, dynamic> _map(dynamic v) => Map<String, dynamic>.from(v as Map);
  List<Map<String, dynamic>> _list(dynamic v) =>
      ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  // ---- Product catalog (shared with the customer app) --------------------

  /// Creates ([productId] null) or updates a product. The database checks the
  /// `manage_products` permission and branch scope; customers read the same rows.
  Future<String> saveProduct({
    String? productId,
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
  }) async =>
      (await _rpc('staff_save_product', {
        'p_product_id': productId,
        'p_name': name,
        'p_description': description,
        'p_category_id': categoryId,
        'p_price': price,
        'p_sku': sku,
        'p_images': images,
        'p_is_active': isActive,
        'p_is_featured': isFeatured,
        'p_variants': variants,
        'p_branch_ids': branchIds,
      })) as String;

  Future<void> setProductActive(String productId, bool isActive) =>
      _rpc('staff_set_product_active', {'p_product_id': productId, 'p_is_active': isActive});

  Future<String> saveCategory({String? categoryId, required String label, String? iconName, int? sortOrder}) async =>
      (await _rpc('staff_save_category', {
        'p_category_id': categoryId,
        'p_label': label,
        'p_icon_name': iconName,
        'p_sort_order': sortOrder,
      })) as String;

  // ---- Account / dashboard ------------------------------------------------

  Future<StaffDashboard> getDashboard(String? branchId) async =>
      StaffDashboard.fromJson(_map(await _rpc('staff_get_dashboard', {'p_branch_id': branchId})));

  // ---- Inventory ------------------------------------------------------------

  /// Products currently switched off. Active staff may read these (RLS policy
  /// "staff read all products"); customers cannot.
  Future<List<InactiveProduct>> listInactiveProducts() => _guard(() async {
    final rows = await _client
        .from('products')
        .select('id, name, price, sku')
        .eq('is_active', false)
        .order('name');
    return _list(rows).map(InactiveProduct.fromJson).toList();
  });

  /// Owner-only sales figures, computed by the database
  /// (`owner_sales_summary`). [days] is clamped to 1-365 server-side.
  Future<OwnerSalesSummary> getOwnerSalesSummary({int days = 30}) async =>
      OwnerSalesSummary.fromJson(_map(await _rpc('owner_sales_summary', {'p_days': days})));

  Future<StaffInventorySnapshot> getInventory(String? branchId) async {
    final data = _map(await _rpc('staff_get_inventory', {'p_branch_id': branchId}));
    final resolvedBranch = data['branch_id'] as String;
    final itemRows = _list(data['items']);
    final batchRows = _list(data['batches']);

    final itemByVariant = {for (final r in itemRows) r['variant_id'] as String: r};

    final batches = <InventoryBatch>[
      for (final b in batchRows)
        InventoryBatch.fromJson(
          b,
          variantLabel: (itemByVariant[b['variant_id']]?['variant_label'] as String?) ?? '',
          restockThreshold: (itemByVariant[b['variant_id']]?['restock_threshold'] as num?)?.toInt(),
          variantStock: (itemByVariant[b['variant_id']]?['quantity'] as num?)?.toInt() ?? 0,
        ),
    ];

    final byVariant = <String, List<InventoryBatch>>{};
    for (final b in batches) {
      byVariant.putIfAbsent(b.variantId, () => []).add(b);
    }

    final branchName = data['branch_name'] as String?;
    final items = <InventoryItem>[
      for (final r in itemRows)
        InventoryItem(
          productId: r['product_id'] as String,
          variantId: r['variant_id'] as String,
          productName: (r['product_name'] as String?) ?? '',
          variantLabel: (r['variant_label'] as String?) ?? '',
          sku: (r['sku'] as String?) ?? '',
          categoryId: (r['category_id'] as String?) ?? '',
          price: (r['price'] as num?)?.toDouble() ?? 0,
          quantity: (r['quantity'] as num?)?.toInt() ?? 0,
          restockThreshold: (r['restock_threshold'] as num?)?.toInt(), // null = Not set
          batchedQuantity: (r['batched_quantity'] as num?)?.toInt() ?? 0,
          branch: branchName,
          branchId: resolvedBranch,
          batches: byVariant[r['variant_id'] as String] ?? const [],
        ),
    ];
    return StaffInventorySnapshot(branchId: resolvedBranch, items: items, batches: batches);
  }

  Future<String> receiveBatch({
    required String branchId,
    required String variantId,
    required String batchCode,
    required int quantity,
    required DateTime expirationDate,
    DateTime? receivedDate,
    int? restockThreshold,
    bool assignExisting = false,

    /// Makes a retry of THIS request safe: the server creates one batch and
    /// replays its id (instead of "batch code already exists"). See
    /// `RequestKeyHolder`.
    String? idempotencyKey,
  }) async {
    final id = await _rpc('staff_receive_batch', {
      'p_branch_id': branchId,
      'p_variant_id': variantId,
      'p_batch_code': batchCode,
      'p_quantity': quantity,
      'p_expiration_date': _date(expirationDate),
      'p_received_date': receivedDate == null ? null : _date(receivedDate),
      'p_restock_threshold': restockThreshold,
      'p_assign_existing': assignExisting,
      'p_idempotency_key': ?idempotencyKey,
    });
    return id as String;
  }

  /// Returns `{previous_quantity, new_quantity, adjustment}`.
  Future<Map<String, dynamic>> adjustBatch({
    required String batchId,
    required int delta,
    required String reason,
    String? note,

    /// Makes a retry of THIS request safe: the server applies it once and
    /// replays the original result. See `RequestKeyHolder`.
    String? idempotencyKey,
  }) async =>
      _map(await _rpc('staff_adjust_batch', {
        'p_batch_id': batchId,
        'p_delta': delta,
        'p_reason': reason,
        'p_note': note,
        'p_idempotency_key': ?idempotencyKey,
      }));

  // ---- Transfers --------------------------------------------------------------

  Future<List<StockTransfer>> listTransfers(String? branchId) async =>
      _list(await _rpc('staff_list_transfers', {'p_branch_id': branchId}))
          .map(StockTransfer.fromJson)
          .toList();

  Future<String> requestTransfer({
    required String fromBranchId,
    required String toBranchId,
    required String variantId,
    required int quantity,
    String? note,

    /// Makes a retry of THIS request safe: the server creates one transfer and
    /// replays its id. See `RequestKeyHolder`.
    String? idempotencyKey,
  }) async =>
      (await _rpc('staff_request_transfer', {
        'p_from_branch_id': fromBranchId,
        'p_to_branch_id': toBranchId,
        'p_variant_id': variantId,
        'p_quantity': quantity,
        'p_note': note,
        'p_idempotency_key': ?idempotencyKey,
      })) as String;

  /// [action]: ship | reject (source branch) or cancel | receive (destination).
  Future<void> respondTransfer(String transferId, String action) =>
      _rpc('staff_respond_transfer', {'p_transfer_id': transferId, 'p_action': action});

  // ---- Orders / payments / sales -----------------------------------------------

  Future<List<StaffOrder>> listOrders({
    String? branchId,
    List<String>? statuses,
    DateTime? since,
    int limit = 100,
    String? orderId,
  }) async =>
      _list(await _rpc('staff_list_orders', {
        'p_branch_id': branchId,
        'p_statuses': statuses,
        'p_since': since?.toUtc().toIso8601String(),
        'p_limit': limit,
        'p_order_id': orderId,
      })).map(StaffOrder.fromJson).toList();

  Future<StaffOrder?> fetchOrder(String? branchId, String orderId) async {
    final rows = await listOrders(branchId: branchId, orderId: orderId, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateOrderStatus(String orderId, String status, {String? note}) =>
      _rpc('staff_update_order_status', {'p_order_id': orderId, 'p_status': status, 'p_note': note});

  Future<void> confirmPayment(String orderId, {String? reference}) =>
      _rpc('staff_confirm_payment', {'p_order_id': orderId, 'p_reference': reference});

  Future<List<CustomerMatch>> lookupCustomer(String query) async =>
      _list(await _rpc('staff_lookup_customer', {'p_query': query}))
          .map(CustomerMatch.fromJson)
          .toList();

  /// RFID loyalty cards (migration 20261011000000_loyalty_cards.sql). The reader
  /// "types" the card UID; the server hashes it and decides everything else.
  /// Returns the card label (e.g. GK-3F9A-71C2).
  Future<String> registerLoyaltyCard({
    required String cardUid,
    required String customerUid,
    required String idempotencyKey,
  }) async =>
      _map(await _rpc('staff_register_loyalty_card', {
        'p_card_uid': cardUid,
        'p_customer_uid': customerUid,
        'p_idempotency_key': idempotencyKey,
      }))['label'] as String;

  /// Replaces the customer's active (or blocked) card; the old one stops working.
  Future<String> replaceLoyaltyCard({
    required String customerUid,
    required String newCardUid,
    required String reason,
    required String idempotencyKey,
  }) async =>
      _map(await _rpc('staff_replace_loyalty_card', {
        'p_customer_uid': customerUid,
        'p_new_card_uid': newCardUid,
        'p_reason': reason,
        'p_idempotency_key': idempotencyKey,
      }))['label'] as String;

  Future<PosSaleResult> createPosSale({
    required String branchId,
    required Map<String, int> quantitiesByVariant,
    required String paymentMethod,
    required String idempotencyKey,
    String? paymentReference,
    double? cashReceived,
    String? customerUid,
  }) async =>
      PosSaleResult.fromJson(_map(await _rpc('staff_create_pos_sale', {
        'p_branch_id': branchId,
        'p_items': [
          for (final e in quantitiesByVariant.entries) {'variant_id': e.key, 'quantity': e.value},
        ],
        'p_payment_method': paymentMethod,
        'p_payment_reference': paymentReference,
        'p_cash_received': cashReceived,
        'p_customer_uid': customerUid,
        'p_idempotency_key': idempotencyKey,
      })));

  // ---- Refunds -------------------------------------------------------------------

  // ---- Cash drawer shifts, voids, returns (migration 20261010000000) -------
  // The shift summaries are returned as plain maps (keys documented in the
  // migration: opening_cash, cash_sales, cash_refunds, paid_in, paid_out,
  // expected_cash, counted_cash, cash_difference, transaction_count, ...).

  /// The signed-in cashier's open shift with live totals, or null.
  Future<Map<String, dynamic>?> currentShift() async {
    final r = await _rpc('staff_get_current_shift');
    return r == null ? null : _map(r);
  }

  Future<Map<String, dynamic>> openShift(String branchId, double openingCash, {String? requestKey}) async =>
      _map(await _rpc('staff_open_shift', {
        'p_branch_id': branchId,
        'p_opening_cash': openingCash,
        'p_idempotency_key': requestKey,
      }));

  /// [type]: 'paid_in' | 'paid_out'.
  Future<Map<String, dynamic>> recordCashMovement(String sessionId, String type, double amount, String reason,
          {String? requestKey}) async =>
      _map(await _rpc('staff_record_cash_movement', {
        'p_session_id': sessionId,
        'p_type': type,
        'p_amount': amount,
        'p_reason': reason,
        'p_idempotency_key': requestKey,
      }));

  /// A note is required by the server when the count differs from expected.
  Future<Map<String, dynamic>> closeShift(String sessionId, double countedCash, {String? notes, String? requestKey}) async =>
      _map(await _rpc('staff_close_shift', {
        'p_session_id': sessionId,
        'p_counted_cash': countedCash,
        'p_notes': notes,
        'p_idempotency_key': requestKey,
      }));

  Future<Map<String, dynamic>> cashierDailySummary(String branchId, {DateTime? day}) async =>
      _map(await _rpc('staff_cashier_daily_summary', {
        'p_branch_id': branchId,
        'p_date': day == null ? null : '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
      }));

  /// Voids today's in-store sale while its shift is open. Needs the
  /// 'void_pos_sales' permission (owner, or granted to a manager).
  Future<Map<String, dynamic>> voidPosSale(String orderId, String reason, {String? requestKey}) async =>
      _map(await _rpc('staff_void_pos_sale', {
        'p_order_id': orderId,
        'p_reason': reason,
        'p_idempotency_key': requestKey,
      }));

  Future<List<StaffRefund>> listRefunds(String? branchId) async =>
      _list(await _rpc('staff_list_refunds', {'p_branch_id': branchId}))
          .map(StaffRefund.fromJson)
          .toList();

  /// [action]: approve | reject | process | complete.
  Future<void> reviewRefund(String refundId, String action) =>
      _rpc('staff_review_refund', {'p_refund_id': refundId, 'p_action': action});

  /// Sends an approved online refund back to the customer's GCash / Maya / card
  /// through the `hitpay-refund` Edge Function (HitPay Refund API). The amount
  /// and HitPay payment id come from the database; a refund can never be sent
  /// twice. Returns a message for the staff member; throws [AppError] when
  /// HitPay refused it or did not answer (then check the HitPay dashboard).
  Future<String> sendRefundViaHitpay(String refundId) async {
    final token = await SupabaseToken.fetch();
    if (token == null) {
      throw const AppError(AppErrorKind.authExpired, 'Please sign in again.');
    }
    try {
      final response = await _client.functions.invoke(
        'hitpay-refund',
        headers: {'Authorization': 'Bearer $token'},
        body: {'refund_id': refundId},
      ).timeout(const Duration(seconds: 40));
      final data = response.data;
      final status = data is Map ? data['status'] : null;
      if (status == 'succeeded') return 'Money sent back through HitPay. The refund is completed.';
      if (status == 'pending') return 'HitPay accepted the refund and is still processing it.';
      throw const AppError(AppErrorKind.refundFailed, 'HitPay did not confirm the refund. Check the HitPay dashboard.');
    } on FunctionException catch (e) {
      // 422 {status: failed, error}: HitPay refused it (still approved, can retry).
      // 409 {error}: the database refused (not allowed / already sent / in flight).
      // 502 {error}: HitPay did not answer.
      final details = e.details;
      final error = details is Map && details['error'] is String ? details['error'] as String : null;
      final refused = details is Map && details['status'] == 'failed';
      throw AppError(
        AppErrorKind.refundFailed,
        refused
            ? 'HitPay refused the refund: ${error ?? 'no reason given'}. It is still approved; try again or refund from the HitPay dashboard.'
            : (error ?? 'The refund could not be sent. Check the HitPay dashboard.'),
      );
    } on AppError {
      rethrow;
    } catch (e) {
      throw AppErrors.from(e);
    }
  }

  // ---- Notifications (RLS: a person only ever sees their own) -----------------------

  Future<List<StaffNotification>> fetchNotifications() => _guard(() async {
        final rows = await _client
            .from('staff_notifications')
            .select()
            .order('created_at', ascending: false)
            .limit(100);
        return List<Map<String, dynamic>>.from(rows).map(StaffNotification.fromRow).toList();
      });

  Future<void> markNotificationRead(String id) =>
      _guard(() async => _client.from('staff_notifications').update({'read': true}).eq('id', id));

  Future<void> markAllNotificationsRead() => _guard(
      () async => _client.from('staff_notifications').update({'read': true}).eq('read', false));

  Future<void> deleteNotification(String id) =>
      _guard(() async => _client.from('staff_notifications').delete().eq('id', id));

  // ---- Owner provisioning ------------------------------------------------------------

  Future<void> upsertStaffMember({
    required String firebaseUid,
    required String fullName,
    required String email,
    required String role,
    String? branchName,
    bool isActive = true,
  }) =>
      _rpc('owner_upsert_staff_member', {
        'p_firebase_uid': firebaseUid,
        'p_full_name': fullName,
        'p_email': email,
        'p_role': role,
        'p_branch_name': branchName,
        'p_is_active': isActive,
      });

  Future<void> setStaffActive(String firebaseUid, bool isActive) =>
      _rpc('owner_set_staff_active', {'p_firebase_uid': firebaseUid, 'p_is_active': isActive});

  /// Removes a `staff_members` row outright. Used ONLY to roll back a staff
  /// row just created by [upsertStaffMember] when a later step of account
  /// creation fails (e.g. the Firestore profile write) — never for normal
  /// offboarding, which should deactivate via [setStaffActive] instead so
  /// the staff member's history/attribution isn't lost.
  Future<void> removeStaffMember(String firebaseUid) =>
      _rpc('owner_delete_staff_member', {'p_firebase_uid': firebaseUid});

  String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

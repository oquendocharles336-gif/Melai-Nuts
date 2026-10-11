/// The refund state of one order, computed by the database
/// (`_order_refund_json`, migration 20261015000000_refunds_in_analytics.sql).
///
/// Sent with staff order lists (`staff_list_orders.refund_summary`), the
/// website's order list and the customer's own orders
/// (`get_my_order_refunds`). Nothing here is calculated on the device.
class OrderRefundSummary {
  /// 'none' | 'pending' | 'partial' | 'full'
  final String state;

  /// Completed refunds on the order (partial refunds included).
  final double refundedAmount;
  final int refundCount;
  final int refundedUnits;
  final DateTime? refundedAt;

  /// Requested / approved / processing right now: not deducted yet.
  final double pendingAmount;
  final String? pendingStatus;

  /// Loyalty points taken back because of the refund (in proportion to the
  /// amount refunded).
  final int pointsReversed;

  /// What can still be refunded on the order (paid − completed refunds).
  final double? refundableAmount;

  const OrderRefundSummary({
    required this.state,
    required this.refundedAmount,
    required this.refundCount,
    required this.refundedUnits,
    required this.refundedAt,
    required this.pendingAmount,
    required this.pendingStatus,
    required this.pointsReversed,
    required this.refundableAmount,
  });

  bool get isPartial => state == 'partial';
  bool get isFull => state == 'full';
  bool get isRefunded => isPartial || isFull;
  bool get hasPending => pendingAmount > 0;

  /// "Partially refunded" / "Refunded" / "Refund pending", or null when none.
  String? get label => switch (state) {
        'partial' => 'Partially refunded',
        'full' => 'Refunded',
        'pending' => 'Refund pending',
        _ => null,
      };

  /// null when [j] is missing (an older server): screens then show "—".
  static OrderRefundSummary? fromJson(dynamic j) {
    if (j is! Map) return null;
    final at = j['refunded_at'];
    return OrderRefundSummary(
      state: (j['state'] as String?) ?? 'none',
      refundedAmount: (j['refunded_amount'] as num?)?.toDouble() ?? 0,
      refundCount: (j['refund_count'] as num?)?.toInt() ?? 0,
      refundedUnits: (j['refunded_units'] as num?)?.toInt() ?? 0,
      refundedAt: at is String ? DateTime.tryParse(at)?.toLocal() : null,
      pendingAmount: (j['pending_amount'] as num?)?.toDouble() ?? 0,
      pendingStatus: j['pending_status'] as String?,
      pointsReversed: (j['points_reversed'] as num?)?.toInt() ?? 0,
      refundableAmount: (j['refundable_amount'] as num?)?.toDouble(),
    );
  }
}

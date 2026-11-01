/// The checkout preview of a pickup order's downpayment, worked out by the
/// server (`cod_downpayment_quote`). `place_order` works it out again for itself,
/// so this is only ever what the customer is shown beforehand.
class CodDownpaymentQuote {
  final bool required;
  final double amount;
  final double balance;
  final int? expiryMinutes;

  /// The percent the owner set, or null for a fixed amount.
  final double? percent;
  final int? pickupDays;

  const CodDownpaymentQuote({
    required this.required,
    required this.amount,
    required this.balance,
    this.expiryMinutes,
    this.percent,
    this.pickupDays,
  });

  factory CodDownpaymentQuote.fromJson(Map<String, dynamic> j) => CodDownpaymentQuote(
        required: (j['required'] as bool?) ?? false,
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        balance: (j['balance'] as num?)?.toDouble() ?? 0,
        expiryMinutes: (j['expiry_minutes'] as num?)?.toInt(),
        percent: (j['percent'] as num?)?.toDouble(),
        pickupDays: (j['pickup_days'] as num?)?.toInt(),
      );
}

/// The online part of a pickup order (`public.order_downpayments`). The rest is the
/// order's `payments` row, paid in cash at the counter.
class OrderDownpayment {
  final double amount;

  /// pending | processing | success | failed | expired | refunded | forfeited
  final String status;
  final DateTime? expiresAt;

  /// What this order was placed with: changing the settings later never touches it.
  final double? percent;
  final int? pickupDays;

  const OrderDownpayment({
    required this.amount,
    required this.status,
    this.expiresAt,
    this.percent,
    this.pickupDays,
  });

  bool get isPaid => status == 'success' || status == 'refunded' || status == 'forfeited';

  /// The order was not picked up in time, so the shop kept this.
  bool get isForfeited => status == 'forfeited';
  bool get isExpired => status == 'expired';

  /// Can still be paid, as far as this device knows. The server decides.
  bool get isOpen => status == 'pending' || status == 'processing' || status == 'failed';

  /// The time limit has passed, even if the server's job has not cancelled the order yet.
  bool isPastLimit(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  factory OrderDownpayment.fromRow(Map<String, dynamic> row) => OrderDownpayment(
        amount: (row['amount'] as num).toDouble(),
        status: (row['status'] as String?) ?? 'pending',
        expiresAt: DateTime.tryParse(row['expires_at'] as String? ?? '')?.toLocal(),
        percent: (row['percent'] as num?)?.toDouble(),
        pickupDays: (row['pickup_days'] as num?)?.toInt(),
      );
}

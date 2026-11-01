/// The checkout preview of a Cash on Delivery downpayment, worked out by the
/// server (`cod_downpayment_quote`). `place_order` works it out again for itself,
/// so this is only ever what the customer is shown beforehand.
class CodDownpaymentQuote {
  final bool required;
  final double amount;
  final double balance;
  final int? expiryMinutes;

  const CodDownpaymentQuote({
    required this.required,
    required this.amount,
    required this.balance,
    this.expiryMinutes,
  });

  factory CodDownpaymentQuote.fromJson(Map<String, dynamic> j) => CodDownpaymentQuote(
        required: (j['required'] as bool?) ?? false,
        amount: (j['amount'] as num?)?.toDouble() ?? 0,
        balance: (j['balance'] as num?)?.toDouble() ?? 0,
        expiryMinutes: (j['expiry_minutes'] as num?)?.toInt(),
      );
}

/// The online part of a Cash on Delivery order (`public.order_downpayments`).
/// The rest is the order's `payments` row, collected in cash on delivery.
class OrderDownpayment {
  final double amount;

  /// pending | processing | success | failed | expired | refunded
  final String status;
  final DateTime? expiresAt;

  const OrderDownpayment({required this.amount, required this.status, this.expiresAt});

  bool get isPaid => status == 'success' || status == 'refunded';
  bool get isExpired => status == 'expired';

  /// Can still be paid, as far as this device knows. The server decides.
  bool get isOpen => status == 'pending' || status == 'processing' || status == 'failed';

  /// The time limit has passed, even if the server's job has not cancelled the order yet.
  bool isPastLimit(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  factory OrderDownpayment.fromRow(Map<String, dynamic> row) => OrderDownpayment(
        amount: (row['amount'] as num).toDouble(),
        status: (row['status'] as String?) ?? 'pending',
        expiresAt: DateTime.tryParse(row['expires_at'] as String? ?? '')?.toLocal(),
      );
}

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

/// The checkout preview of a FIRST order (`first_order_quote`, migration 20261118000000):
/// a customer with no paid online order yet pays 50% or 100% online first. The amounts come
/// from the server; `place_order` works them out again for itself.
class FirstOrderQuote {
  /// False for a returning customer (normal checkout).
  final bool firstOrder;
  final double total;
  final double halfAmount;
  final double halfBalance;
  final double fullAmount;
  final int expiryMinutes;

  /// An earlier first order still waiting for its online payment (only one at a time).
  final String? pendingOrderId;
  final bool onlinePaymentEnabled;

  const FirstOrderQuote({
    required this.firstOrder,
    this.total = 0,
    this.halfAmount = 0,
    this.halfBalance = 0,
    this.fullAmount = 0,
    this.expiryMinutes = 30,
    this.pendingOrderId,
    this.onlinePaymentEnabled = false,
  });

  static const FirstOrderQuote returning = FirstOrderQuote(firstOrder: false);

  static String? _nonEmpty(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

  factory FirstOrderQuote.fromJson(Map<String, dynamic> j) => FirstOrderQuote(
        firstOrder: j['first_order'] == true,
        total: (j['total'] as num?)?.toDouble() ?? 0,
        halfAmount: (j['half_amount'] as num?)?.toDouble() ?? 0,
        halfBalance: (j['half_balance'] as num?)?.toDouble() ?? 0,
        fullAmount: (j['full_amount'] as num?)?.toDouble() ?? 0,
        expiryMinutes: (j['expiry_minutes'] as num?)?.toInt() ?? 30,
        pendingOrderId: _nonEmpty(j['pending_order_id']),
        onlinePaymentEnabled: j['online_payment_enabled'] == true,
      );
}

/// The two first-order choices, as the server knows them (`p_first_order_payment`).
enum FirstOrderChoice {
  half('half'),
  full('full');

  final String wire;
  const FirstOrderChoice(this.wire);
}

/// The online part of an order (`public.order_downpayments`): a pickup downpayment, or the
/// 50% / 100% a first order pays online. The rest is the order's `payments` row, paid in
/// cash at the counter / on delivery.
class OrderDownpayment {
  final double amount;

  /// pending | processing | success | failed | expired | refunded | forfeited
  final String status;
  final DateTime? expiresAt;

  /// What this order was placed with: changing the settings later never touches it.
  final double? percent;
  final int? pickupDays;

  /// 'cod' (pickup downpayment setting) or 'first_order'.
  final String kind;

  /// First orders: 'half' or 'full'.
  final String? choice;

  const OrderDownpayment({
    required this.amount,
    required this.status,
    this.expiresAt,
    this.percent,
    this.pickupDays,
    this.kind = 'cod',
    this.choice,
  });

  bool get isFirstOrder => kind == 'first_order';

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
        kind: (row['kind'] as String?) ?? 'cod',
        choice: row['choice'] as String?,
      );
}

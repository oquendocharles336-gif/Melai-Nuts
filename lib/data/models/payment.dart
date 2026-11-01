import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// The `payments.method` codes. The names must match the database's
/// payments_method_check. `online` means paid through HitPay, method not known
/// (yet); it is also what a code added after this build was released reads as.
enum PaymentMethod {
  gcash,
  maya,
  card,
  cash,
  qrph,
  grabpay,
  shopeepay,
  spaylater,
  billease,
  wechat,
  unionbank,
  instapay,
  pesonet,
  bayad,
  ecpay,
  palawan,
  online,
}

extension PaymentMethodX on PaymentMethod {
  String get label {
    switch (this) {
      case PaymentMethod.gcash:
        return 'GCash E-Wallet';
      case PaymentMethod.maya:
        return 'Maya Wallet';
      case PaymentMethod.card:
        return 'Debit / Credit Card';
      case PaymentMethod.cash:
        return 'Cash on Delivery / Pickup';
      case PaymentMethod.qrph:
        return 'QR Ph';
      case PaymentMethod.grabpay:
        return 'GrabPay';
      case PaymentMethod.shopeepay:
        return 'ShopeePay';
      case PaymentMethod.spaylater:
        return 'SPayLater';
      case PaymentMethod.billease:
        return 'BillEase';
      case PaymentMethod.wechat:
        return 'WeChat Pay';
      case PaymentMethod.unionbank:
        return 'UnionBank Online';
      case PaymentMethod.instapay:
        return 'InstaPay';
      case PaymentMethod.pesonet:
        return 'PESONet';
      case PaymentMethod.bayad:
        return 'Bayad Center';
      case PaymentMethod.ecpay:
        return 'ECPay';
      case PaymentMethod.palawan:
        return 'Palawan Pawnshop';
      case PaymentMethod.online:
        return 'Online Payment';
    }
  }

  String get subtitle {
    switch (this) {
      case PaymentMethod.gcash:
        return 'Instant QR scan / mobile pay';
      case PaymentMethod.maya:
        return 'Maya QR / linked bank';
      case PaymentMethod.card:
        return 'Visa, Mastercard';
      case PaymentMethod.cash:
        return 'Pay at store or on delivery';
      case PaymentMethod.qrph:
        return 'Scan with your e-wallet or bank app';
      case PaymentMethod.grabpay:
      case PaymentMethod.shopeepay:
      case PaymentMethod.spaylater:
      case PaymentMethod.billease:
      case PaymentMethod.wechat:
      case PaymentMethod.unionbank:
      case PaymentMethod.instapay:
      case PaymentMethod.pesonet:
      case PaymentMethod.bayad:
      case PaymentMethod.ecpay:
      case PaymentMethod.palawan:
      case PaymentMethod.online:
        return 'Paid through HitPay';
    }
  }

  IconData get icon {
    switch (this) {
      case PaymentMethod.gcash:
        return Icons.account_balance_wallet_rounded;
      case PaymentMethod.maya:
        return Icons.qr_code_2_rounded;
      case PaymentMethod.card:
        return Icons.credit_card_rounded;
      case PaymentMethod.cash:
        return Icons.payments_rounded;
      case PaymentMethod.qrph:
        return Icons.qr_code_2_rounded;
      case PaymentMethod.grabpay:
      case PaymentMethod.shopeepay:
      case PaymentMethod.spaylater:
      case PaymentMethod.billease:
      case PaymentMethod.wechat:
      case PaymentMethod.online:
        return Icons.account_balance_wallet_rounded;
      case PaymentMethod.unionbank:
      case PaymentMethod.instapay:
      case PaymentMethod.pesonet:
      case PaymentMethod.bayad:
      case PaymentMethod.ecpay:
      case PaymentMethod.palawan:
        return Icons.account_balance_rounded;
    }
  }
}

enum PaymentStatus { pending, processing, success, failed, refunded }

extension PaymentStatusX on PaymentStatus {
  String get label {
    switch (this) {
      case PaymentStatus.pending:
        return 'Pending';
      case PaymentStatus.processing:
        return 'Processing';
      case PaymentStatus.success:
        return 'Paid';
      case PaymentStatus.failed:
        return 'Failed';
      case PaymentStatus.refunded:
        return 'Refunded';
    }
  }

  Color get color {
    switch (this) {
      case PaymentStatus.pending:
      case PaymentStatus.processing:
        return AppColors.warning;
      case PaymentStatus.success:
        return AppColors.success;
      case PaymentStatus.failed:
        return AppColors.error;
      case PaymentStatus.refunded:
        return AppColors.textSecondary;
    }
  }
}

class PaymentTransaction {
  final String id;
  final String orderId;
  final DateTime date;
  final PaymentMethod method;
  final PaymentStatus status;
  final double amount;
  final String referenceNumber;

  const PaymentTransaction({
    required this.id,
    required this.orderId,
    required this.date,
    required this.method,
    required this.status,
    required this.amount,
    required this.referenceNumber,
  });

  factory PaymentTransaction.fromRow(Map<String, dynamic> row) {
    return PaymentTransaction(
      id: row['id'] as String,
      orderId: row['order_id'] as String,
      date: DateTime.parse(row['created_at'] as String).toLocal(),
      // A code this build does not know must never stop the payment from loading.
      method: PaymentMethod.values.asNameMap()[row['method']] ?? PaymentMethod.online,
      status: PaymentStatus.values.byName(row['status'] as String),
      amount: (row['amount'] as num).toDouble(),
      referenceNumber: row['reference_number'] as String,
    );
  }
}

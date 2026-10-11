import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

enum PaymentMethod { gcash, maya, card, cash }

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
      method: PaymentMethod.values.byName(row['method'] as String),
      status: PaymentStatus.values.byName(row['status'] as String),
      amount: (row['amount'] as num).toDouble(),
      referenceNumber: row['reference_number'] as String,
    );
  }
}

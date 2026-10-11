import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

enum NotificationCategory { order, payment, refund, loyalty, delivery, promo, system }

extension NotificationCategoryX on NotificationCategory {
  String get label {
    switch (this) {
      case NotificationCategory.order:
        return 'Order Update';
      case NotificationCategory.payment:
        return 'Payment';
      case NotificationCategory.refund:
        return 'Refund';
      case NotificationCategory.loyalty:
        return 'Loyalty & Rewards';
      case NotificationCategory.delivery:
        return 'Delivery';
      case NotificationCategory.promo:
        return 'Promo';
      case NotificationCategory.system:
        return 'System';
    }
  }

  IconData get icon {
    switch (this) {
      case NotificationCategory.order:
        return Icons.receipt_long_rounded;
      case NotificationCategory.payment:
        return Icons.account_balance_wallet_rounded;
      case NotificationCategory.refund:
        return Icons.assignment_return_outlined;
      case NotificationCategory.loyalty:
        return Icons.stars_rounded;
      case NotificationCategory.delivery:
        return Icons.local_shipping_rounded;
      case NotificationCategory.promo:
        return Icons.local_offer_rounded;
      case NotificationCategory.system:
        return Icons.build_circle_outlined;
    }
  }

  Color get color {
    switch (this) {
      case NotificationCategory.order:
        return AppColors.primary;
      case NotificationCategory.payment:
        return AppColors.success;
      case NotificationCategory.refund:
        return AppColors.warning;
      case NotificationCategory.loyalty:
        return AppColors.primaryDark;
      case NotificationCategory.delivery:
        return AppColors.success;
      case NotificationCategory.promo:
        return AppColors.warning;
      case NotificationCategory.system:
        return AppColors.textSecondary;
    }
  }
}

class NotificationItem {
  final String id;
  final NotificationCategory category;
  final String title;
  final String body;
  final DateTime time;
  bool read;

  NotificationItem({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.time,
    this.read = false,
  });

  factory NotificationItem.fromRow(Map<String, dynamic> row) {
    return NotificationItem(
      id: row['id'] as String,
      category: NotificationCategory.values.byName(row['category'] as String),
      title: row['title'] as String,
      body: row['body'] as String,
      time: DateTime.parse(row['created_at'] as String).toLocal(),
      read: (row['read'] as bool?) ?? false,
    );
  }
}

import 'package:flutter/material.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../data/models/order.dart';

/// Small colored pill showing an order's current [OrderStatus].
class OrderStatusBadge extends StatelessWidget {
  final OrderStatus status;

  const OrderStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.isActive) ...[
            Icon(Icons.circle, size: 8, color: status.color),
            const SizedBox(width: 6),
          ],
          Text(
            status.label,
            style: AppTextStyles.labelMd.copyWith(color: status.color),
          ),
        ],
      ),
    );
  }
}

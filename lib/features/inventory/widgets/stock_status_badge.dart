import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Small colored pill showing whether a batch/item is low on stock or
/// healthy — used next to quantities across the Inventory feature.
class StockStatusBadge extends StatelessWidget {
  final bool isLowStock;

  const StockStatusBadge({super.key, required this.isLowStock});

  @override
  Widget build(BuildContext context) {
    final color = isLowStock ? AppColors.error : AppColors.success;
    final bg = isLowStock ? AppColors.errorBg : AppColors.successBg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        isLowStock ? 'Low Stock' : 'Healthy',
        style: AppTextStyles.labelSm.copyWith(color: color),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';

/// Reusable KPI stat tile used across the Owner dashboard/analytics
/// screens: icon, big value, label, and an optional trend/sub line.
class OwnerStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? sub;
  final Color? valueColor;
  final Color? subColor;
  final bool highlight;
  final VoidCallback? onTap;

  const OwnerStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.sub,
    this.valueColor,
    this.subColor,
    this.highlight = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: highlight ? AppColors.errorBg : Colors.white,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(color: highlight ? AppColors.error.withValues(alpha: 0.4) : AppColors.border),
          boxShadow: AppShadows.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: valueColor ?? AppColors.roleOwner),
            const SizedBox(height: 6),
            Text(value, style: AppTextStyles.headlineSm.copyWith(color: valueColor)),
            Text(label, style: AppTextStyles.bodySm),
            if (sub != null) ...[
              const SizedBox(height: 2),
              Text(sub!, style: AppTextStyles.labelSm.copyWith(color: subColor ?? AppColors.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}
